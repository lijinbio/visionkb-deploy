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
bin/visionkb start                       # postgres, neo4j, api (VISIONKB_SERVICES); web if listed there
bin/visionkb health                      # SQL ping, Cypher ping (+ served release), GET /v1/health and /v1/ready,
                                         # web /healthz and /readyz (API ready + MCP child with 8 tools)
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

Services bind `127.0.0.1` on the compute node. The job log prints the tunnel command for the node
(`bin/visionkb tunnel-hint`): the API port, plus the web port when `web` is in `VISIONKB_SERVICES`. From your laptop:

```bash
ssh -N -L 8770:127.0.0.1:8770 -L 8780:127.0.0.1:8780 -J <user>@<login-host> <user>@<compute-node>
curl http://127.0.0.1:8770/v1/health
# web page: http://127.0.0.1:8780/  (the HPC3 serve instance uses VISIONKB_WEB_PORT=18922)
```

Compute nodes accept SSH only while you have a job there. Forward 7474 the same way for the Neo4j browser
(bolt on 7687) if `VISIONKB_NEO4J_HTTP_PORT` is not 0.

## Web home page (service `web`, opt-in)

[visionkb-web](https://github.com/lijinbio/visionkb-web) (`VISIONKB_WEB_IMAGE`): search, entity pages, release
information and a chat that answers with the `visionkb-kg` MCP tools. Add it with
`VISIONKB_SERVICES=postgres neo4j api web`; `bin/visionkb pull` then pulls its image (by digest), `start` starts it
after the API and `stop` stops it first.

- Port: `VISIONKB_WEB_PORT` (default 8780) on `VISIONKB_WEB_HOST` (default 127.0.0.1). It calls the local API
  (`http://127.0.0.1:$VISIONKB_API_PORT/v1`, or `VISIONKB_WEB_API_URL`) with the read token `api_token_read`.
- Access: `bin/visionkb init` writes `<deploy dir>/<instance>/secrets/web_access_codes` (one code per line, >= 16
  characters, mode 600) and `web_secret` (cookie signing key). Read the code there and give it to the people who may
  log in; add lines for more codes and restart web. Re-running `init` on an existing instance adds missing secrets
  and never rotates existing ones. `bin/visionkb config` prints the file's path, never its content.
- Start-up: the app imports take 60-70 s from a SIF on a network filesystem; `start` waits up to `VISIONKB_WEB_START_TIMEOUT`
  (default 300 s) for `/readyz`.

Users bring their own Claude API key: they enter it in the page, it stays in the browser tab (sessionStorage)
and goes only to visionkb-web for the one Anthropic call it is needed for. The deploy never configures a Claude key
(none is passed to the web instance; `ANTHROPIC_*` variables are removed), so the chat works only with a user key.
**Data notice:** a user's questions, that tab's chat history and the tool results (VisionKB facts and HECA atlas
summary values, `access_level = lab`) are sent to Anthropic under the user's own account. The VisionKB API token,
the access code and cookies are not. The page shows this notice before the first chat; give access codes only to
people who may share lab-access summaries with Anthropic under their account's terms.

## What runs where (apptainer, non-root)

| Service | Image entrypoint | Writable binds (all under `<deploy dir>/<instance>/`) | Notes |
|---|---|---|---|
| postgres | official `docker-entrypoint.sh` | `postgres/data` -> `/var/lib/postgresql/data`, `postgres/run` -> `/var/run/postgresql` (socket dir), `tmp/postgres` -> `/tmp` | initdb on first start with `POSTGRES_PASSWORD_FILE`; SCRAM auth for socket and TCP |
| neo4j | official entrypoint (`tini` -> `docker-entrypoint.sh neo4j`) | `neo4j/conf` -> `/var/lib/neo4j/conf` (fresh copy of the image's conf at each start: the entrypoint writes `NEO4J_*` settings into it), `neo4j/logs` -> `/logs`; node-local: `$VISIONKB_STORE_DIR/neo4j/releases/<id>/data` -> `/data`, `.../neo4j/run` -> `/var/lib/neo4j/run`, `.../tmp/neo4j` -> `/tmp` | `TINI_SUBREAPER=1` (tini is not PID 1); `NEO4J_AUTH` is not used, the password is set at load time |
| api | image default (`visionkb-api serve`, UID 10001 in the image; apptainer runs it as you) | `tmp/api` -> `/tmp`; release folder -> `/release` (read-only) | secrets bound one file at a time, read-only; logs to stdout (instance log) |
| web | image default (`visionkb-web serve`, UID 10001 in the image; apptainer runs it as you) | `tmp/web` -> `/tmp` | started from an explicit env file (API URL, bind, secret file paths); `api_token_read`, `web_secret`, `web_access_codes` bound one file at a time, read-only; `APPTAINERENV_*`, `SINGULARITYENV_*` and `ANTHROPIC_*` removed from the apptainer process (apptainer forwards `APPTAINERENV_*` even with `--cleanenv`) |
| loader | `bash libexec/neo4j-load-release.sh` (apptainer exec) | node-local: `$VISIONKB_STORE_DIR/neo4j/releases` -> `/releases`, `.../tmp/load` -> `/tmp`, expected ids -> `/expected` | temporary server on `127.0.0.1:$VISIONKB_NEO4J_LOAD_BOLT_PORT`; node ids and relationship keys compared with the CSVs |

All containers run with `--containall --no-home --home /tmp --cleanenv`: no host environment or home
directory leaks in, and `HOME` points at a private writable `/tmp` (otherwise Java writes dot-files and apptainer
creates the host home path inside the `/data` bind).

## Shared-node caveats

- **Ports on 127.0.0.1 are reachable by every user on the node.** Every service therefore authenticates:
  Neo4j (password), PostgreSQL (SCRAM, also on the socket), API (bearer token; `/v1/health` is open), web (access
  code; `/healthz`, `/readyz` and the static page are open, data needs a login).
  Pick non-default ports (`VISIONKB_*_PORT`) if another user or project already uses them; `start` refuses a port in use.
- **Process arguments are world-readable** (`/proc/*/cmdline`). Passwords are never passed on argv: Neo4j's
  initial password goes through a mode-600 `@argfile`, cypher-shell/psql/pg_dump read the secret file inside the
  container. Do not add `-p <password>` style options anywhere.
- The instance dir is mode 700, secrets 600. Backups are written with umask 027 (group-readable, for the lab).
- Neo4j stores never go on the shared parallel filesystem (see above). PostgreSQL's data stays there (persistent,
  not regenerable); back it up with `visionkb backup`. Request enough node-local disk (`--tmp` / local scratch)
  for the stores you load: roughly the size of the release's `neo4j-import/` CSVs per release, plus the expected-id
  files during a load.
