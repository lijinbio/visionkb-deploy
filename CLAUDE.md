# visionkb-deploy

Deploy-only repo for the VisionKB KG: apptainer/Slurm on the HPC cluster (dev/test), docker compose for a
plain Docker host, Kubernetes on the Eye server (production). No application code; no data in git.

- Contracts live in [docs/contracts.md](docs/contracts.md) (sanitized copy). Change the contract first,
  then the code; list proposed contract changes in the PR.
- Never invent commands, image tags, digests or results. Verify a tag/digest against its registry before
  pinning it in `versions.env`; say in the PR what was run and what was only rendered/validated.
- Secrets only as files (`*_FILE`), mode 600, never on argv (other users can read `/proc/*/cmdline` on
  shared nodes) and never in logs or env files. Templates ship as `*.example*` with `CHANGE_ME` values.
- Hygiene: no personal or cluster paths, user/account names, hostnames, emails, tokens or lab data in any
  file or commit message; use `/path/to/...`, `<partition>`, `<account>`. `scripts/hygiene-check.sh` runs in CI.
- Releases are bundles: the service reads nothing outside the unpacked bundle at run time. Loads go into a
  NEW store; never modify a served store; rollback = switch back.
- After editing `versions.env`, `libexec/neo4j-load-release.sh` or `src/visionkb_deploy/bundle.py`, run
  `bin/visionkb-k8s sync` (CI runs `sync --check`).
- Before a commit: `shellcheck -x bin/* libexec/*.sh slurm/*.sbatch scripts/*.sh && ruff check . &&
  ruff format --check . && yamllint -s . && pytest && bats tests/bats`.
- Version: bump `pyproject.toml`, `src/visionkb_deploy/__init__.py`, `bundle.py __version__` and both CLIs,
  add a CHANGELOG entry, tag `vX.Y.Z`.
