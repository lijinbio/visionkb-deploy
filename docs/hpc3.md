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

## Faster start on a new node: the verified store cache

Node-local stores vanish with the allocation, so a new job used to repeat the whole load:

- verify the release folder;
- derive the expected ids from the CSVs;
- `neo4j-admin database import`;
- `post_import.cypher`;
- the full id check.

Since 0.1.7 every load whose id check passes also writes a **Neo4j dump** of the store to persistent storage. The
dump goes to `<deploy dir>/<instance>/neo4j/dumps/<release>/`:

| File | Content |
|---|---|
| `<release>.dump` | `neo4j-admin database dump`, taken with the server stopped |
| `<release>.dump.sha256` | its sha256 |
| `DUMP.json` | release id, `manifest_sha256`, Neo4j version and image digest, node/relationship counts, `node_ids_sha256`, `rel_keys_sha256`, the id-checked load's time, dump sha256 and size, `created_utc`, deploy version |

The dump is a regular file, so the network filesystem is fine for it; live stores stay node-local, and the
network-FS guard is unchanged.

`ensure-loaded` (and `rollback`, when its target's store is missing) restores from the dump when **all** of these hold:

- `VISIONKB_ID_CHECK=first` (the default);
- `DUMP.json` names the release and its load was id-checked;
- its `manifest_sha256` equals both the load record's and the release source's `manifest.json`;
- its Neo4j image digest equals the configured `VISIONKB_NEO4J_IMAGE`;
- the dump file's sha256 equals the recorded one.

The restore runs `neo4j-admin database load` into the node-local store, sets the password, starts a temporary
server, waits for the indexes, and checks the node/relationship counts against the record and the manifest totals
and an edge's `kg_release`. Otherwise (or if the restore fails), `ensure-loaded` does the full load as before; it
writes a fresh dump afterwards.

- `VISIONKB_ID_CHECK=always`: always the full load with the full id check (no restore).
- `VISIONKB_STORE_DUMPS=0`: write no dumps (and hence never restore).
- `load-release` (incl. `--force`) is always a full load: it first removes the release's old dump, then writes a
  new one if the load passes.
- Only the dumps of the current and previous release are kept: others are removed when the pointers move
  (`load-release`, `rollback`).
- Before writing, `load-release` checks the free space (store size + 1 GB); with too little space it skips the dump
  with a warning. It writes into a temporary folder and renames it atomically.
- `visionkb releases` shows each dump's state (`matches` or why it is stale); `visionkb config` prints `dumps_dir`.
  The restored store's `LOADED.json` says `"id_check":"dump"`; the persistent record keeps the original
  id-checked load.

## Restarting or upgrading a service inside the running job

`slurm/visionkb.sbatch` polls `<instance>/control/` every `VISIONKB_CONTROL_POLL` seconds (default 5, at most
10). It performs restart requests itself, in the batch step, so the instances stay part of the job (an `srun`
step's processes are killed when the step ends). From any node, with a clone whose `versions.env` pins the
image you want:

```bash
bin/visionkb pull web                          # the pinned (e.g. newer) visionkb-web image, by digest
bin/visionkb request-restart --wait web        # queue the request; wait for the job's result (timeout 600 s)
```

The request is a data file (`KEY=VALUE`, mode 600, written atomically into `control/requests/`, control dir mode
700). It names the services, the requesting deploy version, and for each service the resolved image ref and SIF
path. The job re-validates everything before acting:

- the service is known and in its `VISIONKB_SERVICES`;
- the image ref is digest-pinned and from the same repository as the job's configured image for that service;
- the SIF path is exactly `<images dir>/<name>_<tag>_<digest12>.sif`, is a regular file inside the images dir,
  and its `.ref` equals the ref;
- the request is not older than `VISIONKB_REQUEST_MAX_AGE` (3600 s).

Nothing in a request is executed. The job then stops and starts the services with that image and writes
`control/results/<id>.result` (status ok/error, message, images, timings, readiness, job id, node).
`--wait` prints it. If a start with the requested image fails, the job starts the service with its configured
image again (`recovered_<service>=` in the result).

This upgrades `web` (or `api`) to a newer digest-pinned image without resubmitting the job. Restarting `neo4j` or
`postgres` this way is possible but takes the API down (not ready) until they are back. A restarted service keeps
the requested image until the next restart; a new job starts the image of its own clone's `versions.env`.
`process-requests` is what the job runs; it refuses to run outside Slurm (or without `--local`) and on a node
where none of the instance's services run.

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
