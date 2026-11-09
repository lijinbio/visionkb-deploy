# Eye server: production, and how a release gets there

- **Production = the Eye server**: a separate Linux server running Kubernetes. It has **no access to the HPC
  filesystem or the HPC cluster**: pods do not mount it, and nothing in the k8s path uses SSH to the HPC side.
  Deploy with [k8s.md](k8s.md).
- **Dev/test = HPC3** (apptainer, Slurm): [hpc3.md](hpc3.md).
- A plain Docker host (no Kubernetes) can run the same stack with docker compose, see the last section.

## How a release travels from the HPC filesystem to the Eye server

A KG release is a self-contained, relocatable **bundle** (contracts section 1): `<kg_release>.tar` with relative
paths only, plus `<kg_release>.tar.sha256`; `manifest.json` inside lists every file with its sha256. At run time
the service reads only the unpacked bundle.

1. **On HPC3**, build and check the bundle:

   ```bash
   bin/visionkb export-bundle visionkb-2026.11.0
   ```

   This uses `$VISIONKB_DATA_ROOT/kg/bundles/<id>.tar` if `visionkb-kg pack` already wrote it (or packs the
   release folder deterministically if not), verifies the outer sha256, unpacks into a temporary folder to
   verify every manifest checksum, and prints the copy commands. Optionally test exactly that bundle on HPC3:
   `bin/visionkb load-release visionkb-2026.11.0 --bundle <bundles>/visionkb-2026.11.0.tar`.

2. **Move the two files** to the Eye server with whatever path exists between the two networks:

   | Route | Example |
   |---|---|
   | laptop hop (scp twice) | `scp <user>@<hpc-login>:/path/to/bundles/visionkb-2026.11.0.tar* .` then `scp visionkb-2026.11.0.tar* <user>@<eye-server>:/path/to/bundles/` |
   | direct scp/rsync, if the Eye server can reach a login node | `rsync -av --partial <user>@<hpc-login>:/path/to/bundles/visionkb-2026.11.0.tar* /path/to/bundles/` (run on the Eye server; outbound SSH from a person's account, not from the cluster) |
   | Globus | transfer both files between the two endpoints |
   | HTTPS / object store | upload both files to a bucket or web server the cluster can reach; use the fetch-bundle overlay |

   Then on the Eye server: `sha256sum -c visionkb-2026.11.0.tar.sha256`.

3. **Load it into the cluster**:
   - local-bundle overlay: `bin/visionkb-k8s upload-bundle /path/to/bundles/visionkb-2026.11.0.tar`
   - fetch-bundle overlay: `bin/visionkb-k8s fetch-bundle visionkb-2026.11.0`

   Both verify the outer sha256 and every manifest checksum again inside the cluster, and run the load-release
   Job (new store). Then `bin/visionkb-k8s switch visionkb-2026.11.0`; `rollback` returns to the previous one.

Bundles may contain lab-access data (dataset registry, expression summaries of unpublished atlases). Copy them
only to machines approved for that data; delete transit copies (laptop) afterwards. The registry's HPC paths
(`h5ad_path`, `soma_uri`, `bind.path`) are metadata for HPC jobs and are never opened by the service.

## Plain Docker host (docker compose)

For a single host with Docker but without Kubernetes. Same images, the same settings file as `bin/visionkb`, the
same loader; Neo4j and PostgreSQL sit on an internal network and only the API port is published (on
`127.0.0.1` by default).

```bash
cd compose && cp .env.example .env               # set VISIONKB_ENV_FILE, VISIONKB_DEPLOY_DIR, UID/GID
dc() { docker compose --env-file ../versions.env --env-file .env "$@"; }
dc config -q                                     # validate
# secrets + state dirs, with the DSN pointing at the compose service name:
VISIONKB_DEPLOY_DIR=/path/to/visionkb-deploy-state VISIONKB_PG_HOST=postgres VISIONKB_PG_PORT=5432 ../bin/visionkb init
# unpack the bundle where the stack expects it (<deploy dir>/<instance>/bundles/<id>/):
VISIONKB_DEPLOY_DIR=/path/to/visionkb-deploy-state ../bin/visionkb unpack-bundle /path/to/visionkb-2026.11.0.tar
dc --profile load run --rm neo4j-load            # new store for VISIONKB_KG_RELEASE
dc up -d && dc ps                                # healthchecks: pg_isready, cypher-shell, GET /v1/health
```

Switch or roll back: set `VISIONKB_KG_RELEASE` in `compose/.env` (load it first if new), then `dc up -d`; the
neo4j and api containers are recreated on that store. Backup: `dc --profile backup run --rm pg-backup`.

The containers run as `VISIONKB_UID:VISIONKB_GID` (non-root; the deploy dir must be owned by that user), with
`no-new-privileges`; the API container has a read-only root filesystem. Secrets are compose file secrets
mounted at `/run/secrets/<name>`. This file was validated with `docker compose config` but has not been run yet.
