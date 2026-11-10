# Changelog

## 0.1.4 - 2026-11-10

- versions.env: `VISIONKB_MCP_IMAGE` (visionkb-kg MCP server 0.0.1, digest-pinned), `VISIONKB_SKILLS_RELEASE=v0.2.1`
  (aiscientist-skills), `VISIONKB_KG_BUNDLE_SHA256` (bundle sha256 of the default release visionkb-2026.11.0).
- `visionkb pull mcp` pulls the MCP server image (a client tool; not in `VISIONKB_SERVICES`, not started or stopped);
  `visionkb config` prints `mcp_sif`, the MCP/skills pins and the bundle sha.
- Bundle pin: `unpack-bundle` and `load-release --bundle` refuse a bundle of the pinned release whose sha256 differs
  from `VISIONKB_KG_BUNDLE_SHA256`, before anything is unpacked; other releases are not affected. The versions.env
  sha pins only versions.env's own release (an env file selecting another default release without its own sha
  gets no pin). `bundle.py verify-bundle|unpack|fetch --pin RELEASE=SHA256`; `fetch` checks the published
  `.sha256` before downloading the tar.
- Kubernetes: overlays' `release.env` carry `VISIONKB_KG_BUNDLE_SHA256` (`sync` / `switch` / `rollback`;
  `sync --check` fails when stale); `upload-bundle` and the fetch-bundle Job compare it. Applying 0.1.4 rolls neo4j
  and the API once (ConfigMap `visionkb-release` gains the key). Example NetworkPolicy for an in-cluster gateway.
- docs/aiscientist.md: API base URL (Service vs Ingress), read token file, MCP server over stdio (apptainer, Docker),
  skills release install with checksum verification, the 24,000-character paging rule (`next_offset`).
- Smoke test: pin match / mismatch / other release on `unpack-bundle` and `load-release --bundle`; MCP server pulled
  and driven over stdio against the served API (`tests/smoke/mcp_stdio_check.py`).

## 0.1.3 - 2026-11-10

- versions.env: visionkb-api 0.1.4 (digest-pinned).
- `load-release` fails when the imported totals differ from the manifest's `counts.nodes_total` / `edges_total`, or
  when `nodes_by_category` / `edges_by_predicate` do not sum to them (contracts v0.8 section 13); was a warning.
- Fixture releases carry `nodes_total` / `edges_total` and the v0.5 indexes (`rel_id` per type, `gene_symbol`).
- Smoke test: count-mismatch load refused; API fixture loads with equal totals and lists known issue KI-1 in
  `/v1/release`.
- docs/contracts.md: sanitized copy of contracts v0.8.

## 0.1.2 - 2026-11-10

- Neo4j stores, run dir and load scratch on node-local disk (`VISIONKB_STORE_DIR`, default `$TMPDIR` or
  `/tmp/$USER/visionkb/<instance>`): a store written on BeeGFS came back corrupted. `load-release`/`start` refuse a
  store on a network filesystem unless `VISIONKB_ALLOW_NETWORK_STORE=1`. Persistent load records under
  `<instance>/neo4j/loaded/<id>/`.
- `visionkb ensure-loaded [--with-previous]` re-imports on a new node; the sbatch script runs it; `rollback`
  re-imports a missing target.
- Id check on every load (apptainer, k8s Job, compose): all node ids and relationship keys compared with the import
  CSVs (`bundle.py expected-ids`); `load-release --expected-ids DIR`.

## 0.1.1 - 2026-11-09

- versions.env: visionkb-api 0.1.1 (digest-pinned).
- Readiness: k8s readinessProbe and the compose healthcheck use `GET /v1/ready` (liveness stays `/v1/health`);
  `visionkb health` reports `/v1/ready` and fails when it is not 200; `start` reports API readiness.
- Smoke test: `/v1/ready` 503 while neo4j is stopped and 200 after start; visionkb-api fixture bundle as an extra
  cross-track load.
- README status corrected (v0.1.0's tag kept the pre-test wording).

## 0.1.0 - 2026-11-09

- `bin/visionkb`: apptainer deploy for HPC (dev/test): pull (digest-pinned), init (secrets, mode 600),
  verify-release, export-bundle, unpack-bundle, load-release (new store per release, post_import.cypher,
  LOADED.json), start/stop/restart/status/health, backup/restore (pg_dump), rollback by release id.
- `libexec/neo4j-load-release.sh`: one in-container loader for apptainer, compose and Kubernetes.
- `src/visionkb_deploy/bundle.py`: stdlib-only bundle verify/pack/unpack/fetch (contracts v0.4).
- `slurm/visionkb.sbatch`: whole stack in one allocation, periodic health checks, clean stop.
- `compose/`: docker compose stack (internal network, only the API port published).
- `k8s/`: Kustomize base + overlays `local-bundle` and `fetch-bundle`; `bin/visionkb-k8s`.
- CI: shellcheck, ruff, yamllint, bats, pytest (3.12, 3.13; bundle.py on 3.9), compose config, kustomize +
  kubeconform, hygiene check.
