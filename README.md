# visionkb-deploy

Deploy-only repository for the VisionKB knowledge graph: it runs a **KG release** (built by
[visionkb-kg](https://github.com/lijinbio/visionkb-kg)) in Neo4j Community, a PostgreSQL proposals
database, and the read-only [visionkb-api](https://github.com/lijinbio/visionkb-api) service. There is no
application code here, only scripts, manifests and docs. Data never goes into git.

| Environment | Role | How | Doc |
|---|---|---|---|
| Eye server (Kubernetes) | **production** | `k8s/` (Kustomize) + `bin/visionkb-k8s`; release bundles copied in or fetched by URL; no HPC filesystem access | [docs/k8s.md](docs/k8s.md), [docs/eyeserver.md](docs/eyeserver.md) |
| HPC cluster (apptainer, Slurm) | dev / test | `bin/visionkb` + `slurm/visionkb.sbatch`; non-root apptainer instances | [docs/hpc3.md](docs/hpc3.md) |
| Plain Docker host | optional | `compose/docker-compose.yml` | [docs/eyeserver.md](docs/eyeserver.md#plain-docker-host-docker-compose) |

Web home page: the optional service `web` ([visionkb-web](https://github.com/lijinbio/visionkb-web): search, entity
pages, chat) runs next to the API: `VISIONKB_SERVICES=postgres neo4j api web` on HPC (port 8780; the HPC3 serve
instance uses 18922), Ingress `/` on Kubernetes (API at `/v1`), compose profile `web`. Access codes:
`<instance>/secrets/web_access_codes` (written by `init`). Users bring their own Claude key in the browser; questions
and tool results go to Anthropic under their account (data notice in [docs/hpc3.md](docs/hpc3.md#web-home-page-service-web-opt-in)).

Clients: the AiScientist gateway uses the KG through the API, the visionkb-kg MCP server (stdio) and the skills
registry release pinned in versions.env; see [docs/aiscientist.md](docs/aiscientist.md).

All three use the same pinned images ([versions.env](versions.env)), the same settings names
([config/visionkb.env.example](config/visionkb.env.example), contracts section 9), and the same in-container loader
([libexec/neo4j-load-release.sh](libexec/neo4j-load-release.sh)). Contracts: [docs/contracts.md](docs/contracts.md).

## Release lifecycle

1. `visionkb-kg` builds an immutable release folder and a bundle `<kg_release>.tar` + `.tar.sha256`
   (relative paths only, every file checksummed in `manifest.json`).
2. Verify: outer sha256 and every manifest checksum
   ([src/visionkb_deploy/bundle.py](src/visionkb_deploy/bundle.py), stdlib only, Python >= 3.9).
3. Load: `neo4j-admin database import full` into a **new** store for that release, set the Neo4j password
   from a file, apply `post_import.cypher`, wait for indexes, record `LOADED.json`. The served store is never touched.
4. Switch: point the service at the new store (restart). The previous store stays: **rollback** = switch back.

## Quick start (HPC, dev/test)

```bash
cp config/visionkb.env.example /path/to/visionkb/config/visionkb.env   # edit paths and ports
export VISIONKB_ENV_FILE=/path/to/visionkb/config/visionkb.env
bin/visionkb pull                      # apptainer pull of the digest-pinned images
bin/visionkb init                      # instance dirs + secrets (mode 600)
bin/visionkb load-release visionkb-2026.11.0
bin/visionkb start && bin/visionkb health
```

Under Slurm: `sbatch --partition=<partition> --account=<account> slurm/visionkb.sbatch`; reach the API with an
SSH tunnel (printed in the job log).

## Quick start (Eye server, production)

```bash
bin/visionkb-k8s create-secrets --from /path/to/secrets   # files from `bin/visionkb init`
bin/visionkb-k8s apply                                     # overlay from VISIONKB_K8S_OVERLAY
bin/visionkb-k8s upload-bundle /path/to/visionkb-2026.11.0.tar   # or: fetch-bundle visionkb-2026.11.0
bin/visionkb-k8s switch visionkb-2026.11.0
```

## Layout

```
versions.env                 pinned images (by digest, incl. web), the release to serve + its bundle sha256, MCP image, skills release
config/visionkb.env.example  settings template (copy outside git; secrets only as *_FILE paths)
bin/visionkb                 apptainer CLI: pull init load-release start stop status health backup rollback ...
bin/visionkb-k8s             Kubernetes CLI: sync apply create-secrets upload-bundle fetch-bundle switch rollback
libexec/                     in-container loader, shared shell helpers
src/visionkb_deploy/         bundle.py: verify / pack / unpack / fetch release bundles
slurm/visionkb.sbatch        whole stack in one Slurm allocation
compose/                     docker-compose.yml + .env.example
k8s/base, k8s/overlays/{local-bundle,fetch-bundle}   Kustomize manifests
tests/                       bats (CLI parsing), pytest (bundle.py), fixture release generator
docs/                        hpc3.md, eyeserver.md, k8s.md, aiscientist.md, operations.md, contracts.md
```

## Status (v0.1.6)

- HPC apptainer path: end-to-end smoke test on an HPC3 compute node (`tests/smoke/smoke-apptainer.sh`) with the
  pinned images (visionkb-api 0.1.4), two synthetic fixture releases and the visionkb-api fixture bundle. Neo4j
  stores are node-local (a store on BeeGFS was found corrupted, see docs/operations.md); every load checks all node
  ids and relationship keys against the CSVs and the imported totals against the manifest; a new allocation re-imports with `ensure-loaded`.
  `slurm/visionkb.sbatch` ran on a Slurm partition (re-import on the new node, health, clean stop on SIGTERM).
  The bundle of the pinned release must match `VISIONKB_KG_BUNDLE_SHA256` (checked on unpack and load). The
  visionkb-kg MCP server image (`visionkb pull mcp`) was run over stdio against the served API (docs/aiscientist.md).
  The web service (visionkb-web 0.0.2) ran in the smoke test: readiness with the 8 MCP tools, access-code login, the
  KG proxy, no Anthropic variable inside the instance. Its chat was not run with a real Claude key here.
  Results per release: step `05_deploy_smoke` of the VisionKB implementation record.
- docker compose: validated with `docker compose config` (incl. `--profile web`); not run (no Docker on the test host).
- Kubernetes: both overlays render and pass `kubeconform -strict`; not applied to a cluster yet.

## License

MIT, see [LICENSE](LICENSE).
