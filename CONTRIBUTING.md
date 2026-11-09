# Contributing

## Setup

```bash
git clone https://github.com/lijinbio/visionkb-deploy.git && cd visionkb-deploy
uv sync && uv run pytest              # or: pip install -e . pytest ruff yamllint pre-commit
pre-commit install                    # optional: run the checks on every commit
```

shellcheck and bats come from your system or conda (`conda install -c conda-forge shellcheck bats-core`).

## Checks (all run in CI)

| Check | Command |
|---|---|
| Shell | `shellcheck -x bin/visionkb bin/visionkb-k8s libexec/*.sh slurm/visionkb.sbatch scripts/*.sh` |
| Python | `ruff check . && ruff format --check .` |
| YAML | `yamllint -s .` |
| CLI parsing, bundle commands | `bats tests/bats` |
| bundle.py | `pytest` (and Python 3.9 compatibility) |
| compose | `cd compose && docker compose --env-file ../versions.env --env-file .env config -q` |
| k8s | `bin/visionkb-k8s sync --check`; render both overlays; `kubeconform -strict` |
| Hygiene | `scripts/hygiene-check.sh` |

## Conventions

| Topic | Rule |
|---|---|
| Images | `name:tag@sha256:digest` in `versions.env`; verify the digest on the registry first |
| Settings | `VISIONKB_*` names from contracts section 9; plain `KEY=VALUE` files (no shell expansion) |
| Secrets | files only (`*_FILE`), mode 600; examples are `*.example*` with `CHANGE_ME` |
| Shell | `set -euo pipefail`, shellcheck-clean, no secrets on argv |
| Tests | fixture releases are synthetic (`tests/fixtures/make_fixture_release.py`); real-data runs reported in the PR |
| Hygiene | no personal/cluster paths, accounts, hostnames, tokens or lab data |

## Releasing

Bump the version (see CLAUDE.md), add a CHANGELOG entry under the new version, tag `vX.Y.Z` and push the tag;
the Release workflow checks the versions and publishes a GitHub release.
