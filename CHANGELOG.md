# Changelog

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
