# Changelog

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
