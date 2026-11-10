# HPC3 (apptainer + Slurm): dev / test

HPC3 is the **development and test** environment: release builds, atlas conversion, and running a
release locally to test it. **Production runs on the Eye server's Kubernetes cluster** ([k8s.md](k8s.md)),
which cannot read the HPC filesystem; releases travel there as bundles ([eyeserver.md](eyeserver.md)).

Everything runs as your own (non-root) user in apptainer instances. No Docker, no root, no system services.

**Neo4j stores are node-local** (`VISIONKB_STORE_DIR`, default `$TMPDIR/visionkb/<instance>` or
`/tmp/$USER/visionkb/<instance>`): a store written onto BeeGFS came back corrupted, see
[operations.md](operations.md#neo4j-stores-on-network-filesystems-do-not). They vanish with the allocation; in a new
job run `bin/visionkb ensure-loaded` before `start` (the sbatch script does). `load-release` and `start` refuse a
store on a network filesystem unless `VISIONKB_ALLOW_NETWORK_STORE=1`.

## Prerequisites

- apptainer >= 1.1 (`apptainer instance run`). If it is a module, set `VISIONKB_APPTAINER_MODULE=apptainer/<version>`
  (and `VISIONKB_MODULES_INIT` if the `module` command is not defined in batch shells).
- `python3` >= 3.9 (system python is enough: `src/visionkb_deploy/bundle.py` is stdlib only), `curl`, `sha256sum`.
- Disk under `$VISIONKB_WORK_DIR/visionkb-deploy/`: about 0.6 GB for images plus, per loaded release, roughly
  the size of its `neo4j-import/` CSVs.

## Settings

Copy [config/visionkb.env.example](../config/visionkb.env.example) to `$VISIONKB_DATA_ROOT/config/visionkb.env`
(outside git) and edit paths and ports. `bin/visionkb` finds it via `--env-file`, `$VISIONKB_ENV_FILE`, or
`$VISIONKB_DATA_ROOT/config/visionkb.env`. Precedence: environment > env file > `versions.env` > defaults.
`bin/visionkb config` prints the effective settings (never secrets).

## First run

```bash
export VISIONKB_ENV_FILE=/path/to/visionkb/config/visionkb.env
bin/visionkb pull                        # images -> <deploy dir>/images/<name>_<tag>_<digest12>.sif
bin/visionkb init                        # <deploy dir>/<instance>/ (mode 700) + secrets (mode 600)
bin/visionkb load-release visionkb-2026.11.0     # from $VISIONKB_RELEASES_DIR, verified first
bin/visionkb start                       # postgres, neo4j, api (VISIONKB_SERVICES)
bin/visionkb health                      # SQL ping, Cypher ping (+ served release), GET /v1/health and /v1/ready
bin/visionkb stop
```

Loading from a bundle instead of the release folder (exactly what the Eye server receives):

```bash
bin/visionkb export-bundle visionkb-2026.11.0            # verify (or pack) <bundles>/<id>.tar + .sha256
bin/visionkb load-release visionkb-2026.11.0 --bundle /path/to/visionkb-2026.11.0.tar
```

`--bundle` unpacks into `<instance>/bundles/<id>/` (outer sha256 + every manifest checksum), then loads from there.

## Under Slurm

```bash
sbatch --partition=<partition> --account=<account> --mem=16G --time=1-00:00:00 slurm/visionkb.sbatch
```

The job starts the stack, health-checks every `VISIONKB_HEALTH_INTERVAL` seconds (default 300), and stops the
instances cleanly 180 s before the time limit (`--signal=B:TERM@180`) or on `scancel`. Submit from the repo
directory (or set `VISIONKB_DEPLOY_REPO`). Size `--mem` for heap + page cache + PostgreSQL + API (the defaults
`VISIONKB_NEO4J_HEAP=2g`, `VISIONKB_NEO4J_PAGECACHE=2g` fit in 16 GB with room to spare).

### Reaching the services (SSH port forwarding)

Services bind `127.0.0.1` on the compute node. The job log prints the node; from your laptop:

```bash
ssh -N -L 8770:127.0.0.1:8770 -J <user>@<login-host> <user>@<compute-node>
curl http://127.0.0.1:8770/v1/health
```

Compute nodes accept SSH only while you have a job there. Forward 7474 the same way for the Neo4j browser
(bolt on 7687) if `VISIONKB_NEO4J_HTTP_PORT` is not 0.

## What runs where (apptainer, non-root)

| Service | Image entrypoint | Writable binds (all under `<deploy dir>/<instance>/`) | Notes |
|---|---|---|---|
| postgres | official `docker-entrypoint.sh` | `postgres/data` -> `/var/lib/postgresql/data`, `postgres/run` -> `/var/run/postgresql` (socket dir), `tmp/postgres` -> `/tmp` | initdb on first start with `POSTGRES_PASSWORD_FILE`; SCRAM auth for socket and TCP |
| neo4j | official entrypoint (`tini` -> `docker-entrypoint.sh neo4j`) | `neo4j/conf` -> `/var/lib/neo4j/conf` (fresh copy of the image's conf at each start: the entrypoint writes `NEO4J_*` settings into it), `neo4j/logs` -> `/logs`; node-local: `$VISIONKB_STORE_DIR/neo4j/releases/<id>/data` -> `/data`, `.../neo4j/run` -> `/var/lib/neo4j/run`, `.../tmp/neo4j` -> `/tmp` | `TINI_SUBREAPER=1` (tini is not PID 1); `NEO4J_AUTH` is not used, the password is set at load time |
| api | image default (`visionkb-api serve`, UID 10001 in the image; apptainer runs it as you) | `tmp/api` -> `/tmp`; release folder -> `/release` (read-only) | secrets bound one file at a time, read-only; logs to stdout (instance log) |
| loader | `bash libexec/neo4j-load-release.sh` (apptainer exec) | node-local: `$VISIONKB_STORE_DIR/neo4j/releases` -> `/releases`, `.../tmp/load` -> `/tmp`, expected ids -> `/expected` | temporary server on `127.0.0.1:$VISIONKB_NEO4J_LOAD_BOLT_PORT`; node ids and relationship keys compared with the CSVs |

All containers run with `--containall --no-home --home /tmp --cleanenv`: no host environment or home
directory leaks in, and `HOME` points at a private writable `/tmp` (otherwise Java writes dot-files and apptainer
creates the host home path inside the `/data` bind).

## Shared-node caveats

- **Ports on 127.0.0.1 are reachable by every user on the node.** Every service therefore authenticates:
  Neo4j (password), PostgreSQL (SCRAM, also on the socket), API (bearer token; `/v1/health` is open).
  Pick non-default ports (`VISIONKB_*_PORT`) if another user or project already uses them; `start` refuses a port in use.
- **Process arguments are world-readable** (`/proc/*/cmdline`). Passwords are never passed on argv: Neo4j's
  initial password goes through a mode-600 `@argfile`, cypher-shell/psql/pg_dump read the secret file inside the
  container. Do not add `-p <password>` style options anywhere.
- The instance dir is mode 700, secrets 600. Backups are written with umask 027 (group-readable, for the lab).
- Neo4j stores never go on the shared parallel filesystem (see above). PostgreSQL's data stays there (persistent,
  not regenerable); back it up with `visionkb backup`. Request enough node-local disk (`--tmp` / local scratch)
  for the stores you load: roughly the size of the release's `neo4j-import/` CSVs per release, plus the expected-id
  files during a load.
