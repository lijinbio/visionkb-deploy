# Operations

Production = Eye server Kubernetes ([k8s.md](k8s.md)); dev/test = HPC3 apptainer ([hpc3.md](hpc3.md)).
The release mechanics are the same everywhere; the commands differ.

| Task | HPC3 (`bin/visionkb`) | Eye server (`bin/visionkb-k8s`) | Docker host (compose) |
|---|---|---|---|
| Verify a release / bundle | `verify-release ID\|DIR`, `unpack-bundle TAR` | inside `upload-bundle` / `fetch-bundle` and the load Job's verify step | `bin/visionkb unpack-bundle TAR --dest <instance>/bundles` |
| Load (new store) | `load-release ID [--bundle TAR \| --from DIR]` | `load-release ID` | `--profile load run --rm neo4j-load` |
| Serve a loaded release | automatic after load (`--no-activate` to skip), restarts neo4j/api if running | `switch ID` | set `VISIONKB_KG_RELEASE` in `.env`, `up -d` |
| Roll back | `rollback [ID]` | `rollback` | set the previous id, `up -d` |
| Backup proposals | `backup` | CronJob `visionkb-backup` (nightly) | `--profile backup run --rm pg-backup` |
| Restore proposals | `restore DIR --yes` | `kubectl exec` + `pg_restore` (below) | `docker compose exec postgres pg_restore ...` |
| Status / health | `status`, `health` | `status`, `kubectl -n visionkb get pods` | `docker compose ps` |

## Release lifecycle

1. **Verify.** `manifest.json` lists every file with bytes and sha256; the bundle has an outer `.sha256`.
   Verification fails on any mismatch, missing file, file not in the manifest, symlink, absolute or `..` path, or
   `:` in a name (contracts v0.4 section 1). `import.args` may only reference files in the manifest.
2. **Load into a new store.** `libexec/neo4j-load-release.sh` runs `neo4j-admin database import full` into
   `<releases>/<id>.partial/data`, sets the initial password from the secret file, starts a temporary server on a
   private port, applies `post_import.cypher`, waits for all indexes to be ONLINE, records counts in
   `LOADED.json`, stops, and renames `<id>.partial` to `<id>`. A failed load leaves `<id>.partial` for inspection
   and never touches the served store. Before publishing, the loader compares every node id and relationship key
   with the CSVs and fails on any difference. `bin/visionkb` then requires the imported totals to equal the
   manifest's `counts.nodes_total` / `counts.edges_total` (whose `nodes_by_category` / `edges_by_predicate` must sum
   to them, contracts v0.8 section 13); on a difference the store is unpublished, no record is written and no
   pointer moves. Manifests without the totals (before v0.8) fall back to the sums, with a warning.
3. **Switch.** The served store is chosen by a pointer: `<instance>/state/current` (HPC3), the
   `visionkb-release` ConfigMap from `k8s/overlays/<mode>/release.env` (k8s), or `VISIONKB_KG_RELEASE` (compose).
   Neo4j is restarted on the other store; Neo4j serves it read-only (`server.databases.default_to_read_only`).
4. **Rollback.** The previous store is kept, so rollback is a switch back (seconds plus Neo4j start-up).
   `rollback` without an id goes to the previous pointer; `rollback ID` to any loaded release.

`import.args` format expected from visionkb-kg: one neo4j-admin option per line, `--nodes=[Labels=]file[,file]`
and `--relationships=[TYPE=]file[,file]` with paths relative to `neo4j-import/`; other options (e.g.
`--array-delimiter=;`) are passed through. The loader rewrites paths to absolute ones (neo4j-admin needs them)
and puts the database name before the options (both `--nodes` and `--relationships` are variadic).
`--overwrite-destination`, `--report-file`, `--additional-config` and `--expand-commands` are rejected.

## Neo4j stores on network filesystems: do not

In a load rehearsal of `visionkb-2026.11.0` (2,783,649 nodes, 5,119,626 relationships) a store written by
`neo4j-admin import` onto BeeGFS (the HPC parallel filesystem) came back **corrupted**: 4 nodes missing and 41
garbled ids, with no error from the import. The same import on node-local `/tmp` was exact. Since v0.1.2:

- `bin/visionkb` puts Neo4j stores, their run dir and the load scratch on **node-local disk**
  (`VISIONKB_STORE_DIR`, default `$TMPDIR/visionkb/<instance>` when `$TMPDIR` is an absolute local path, else
  `/tmp/$USER/visionkb/<instance>`). `load-release` and `start` refuse a store on BeeGFS/NFS/Lustre/GPFS/CIFS/Ceph
  (by `stat -f`) unless `VISIONKB_ALLOW_NETWORK_STORE=1`, which only turns the refusal into a loud warning.
- Every load compares **all node ids and all relationship keys** (`start|type|end|id`) of the loaded store with the
  import CSVs (`bundle.py expected-ids`, byte for byte after sorting) and fails without publishing the store on
  any difference; counts alone did not show the corruption. `LOADED.json` records `id_check` and both digests.
  The same check runs in the Kubernetes load Job and the compose `neo4j-load` service.
- PostgreSQL (proposals) stays on the persistent deploy dir: it is not regenerable, and node-local data would be
  lost with the allocation. Back it up (`visionkb backup`).
- Kubernetes and compose keep their stores on PVCs / local volumes of the server; use block storage (local disk,
  a block-device StorageClass), not an NFS-backed volume, for `neo4j-releases`.

Node-local stores **vanish with the allocation**. The persistent load record (`<instance>/neo4j/loaded/<id>/`)
remembers what was loaded and from where; in a new job `visionkb ensure-loaded` re-imports the current release
from its recorded source (`slurm/visionkb.sbatch` runs it before `start`), and `rollback` re-imports its target
when that store is missing. A large release takes minutes to re-import; size the job's local disk for it.

## State on disk (HPC3)

```
<deploy dir>/                       persistent (BeeGFS is fine here: logs, records, small files)
├── images/                         *.sif (+ .ref with the pulled reference)
└── <instance>/                     mode 700
    ├── secrets/                    neo4j_password pg_password pg_dsn api_tokens api_token_read (600)
    ├── state/current, previous     release pointers
    ├── neo4j/loaded/<id>/          load record: LOADED.json, SOURCE, STORE, expected-ids.json, load-logs/
    ├── neo4j/{conf,logs}/
    ├── postgres/{data,run}/        proposals database (NOT regenerable: back it up)
    ├── bundles/<id>/               unpacked bundles (load-release --bundle)
    └── run/*.env, tmp/             generated per start
$VISIONKB_STORE_DIR/                node-local, gone with the allocation
├── neo4j/releases/<id>/            data/ (store), load-logs/, LOADED.json
├── neo4j/run/
└── tmp/{neo4j,load}/               JVM scratch, expected-ids files during a load
```

Everything except `postgres/data` and `secrets/` is regenerable from a release. `visionkb releases` shows each
record and whether its store is on the current node. Stores under `<instance>/neo4j/releases/` written by
visionkb-deploy <= 0.1.1 (on the deploy dir) are no longer used: re-load and remove them.

## Verified store cache (dumps) and in-job restarts

- **Dumps:** `<instance>/neo4j/dumps/<release>/` holds one Neo4j dump per release (current and previous only),
  written after an id-checked load and used by `ensure-loaded` / `rollback` on a new node (see
  [hpc3.md](hpc3.md#faster-start-on-a-new-node-the-verified-store-cache)).
  - **Disk:** a dump is usually smaller than the store (compressed). `load-release` skips the dump with a
    warning when the free space is below store size + 1 GB.
  - **Removing:** to drop a dump, delete its folder; the next full load writes it again. A dump whose `DUMP.json`
    does not match (other manifest, other Neo4j image, failed sha256) is never used; the full load replaces it.
  - **Safety:** after a restore the counts, the manifest totals and an edge's `kg_release` are checked, and the dump
    itself comes from a store whose every node id and relationship key matched the CSVs. To repeat the full id check
    on every new node, set `VISIONKB_ID_CHECK=always`.
- **Control dir** `<instance>/control/` (mode 700):
  - `requests/` and `processing/`: request files;
  - `results/`: `<id>.result` and `<id>.log`;
  - `watcher`: the job's last poll (job id, node, time). `request-restart` warns when no job has polled
    recently.

  Requests are validated data, never shell. Old results can be deleted at any time.
- **Restarting neo4j or postgres in the job** stops the API's backing service: `/v1/ready` (and the web page's
  `/readyz`) answers 503 until the service is back. Prefer restarting `web` or `api` only.

## Backups

`bin/visionkb backup` writes `$VISIONKB_BACKUP_DIR/<UTC timestamp>/` with `proposals.pgdump` (`pg_dump -Fc`),
`backup.json` (pointers, sha256) and the current release's `LOADED.json`. Restore with
`bin/visionkb restore <dir> --yes` (`pg_restore --clean --if-exists`).

On Kubernetes the CronJob keeps the newest 14 dumps on `visionkb-backups`; copy them off the cluster too.
Restore: `kubectl -n visionkb cp <dump> postgres-0:/tmp/p.pgdump` then
`kubectl -n visionkb exec -it postgres-0 -- sh -c 'PGPASSWORD="$(cat /run/secrets/visionkb/pg_password)" pg_restore -h 127.0.0.1 -U visionkb -d visionkb --clean --if-exists /tmp/p.pgdump'`.

## Secrets

`bin/visionkb init` generates them once (32-character alphanumeric passwords, 40-character token) and never
overwrites existing files. The API tokens file has lines `token<TAB>scopes` (scopes `read`, `proposals:read`,
`proposals:write`); `api_token_read` holds the read token alone for clients (`VISIONKB_API_TOKEN_FILE`).

The Neo4j password is written into each store at load time. To rotate it: change `neo4j_password`, then
re-load the releases you serve (`load-release ID --force` for a non-current one) - or change it in the running
server with `ALTER CURRENT USER SET PASSWORD FROM ... TO ...` per store.

## Troubleshooting

| Symptom | Check |
|---|---|
| `port N in use` | another instance/user on the node; change `VISIONKB_*_PORT` |
| `<id> exists without LOADED.json` | an interrupted load; `load-release ID` (stale stores are removed) |
| `store ... is not on this node` | new allocation: `visionkb ensure-loaded` (or `rollback`, which re-imports) |
| `network filesystem` refusal | point `VISIONKB_STORE_DIR` at node-local disk; see the section above |
| `id check FAILED` | the store differs from the CSVs: do not serve it; check the store filesystem and disk; the diff is in the load log |
| neo4j `not ready` | `bin/visionkb logs neo4j`; `<instance>/neo4j/logs/neo4j.log`; heap/page cache vs. `--mem` |
| `health`: edge kg_release differs from pointer | the store was loaded from a different release than its name; reload with `--force` |
| k8s neo4j pod stuck in `Init` | the `require-loaded-release` init container: release in `release.env` not loaded yet |
