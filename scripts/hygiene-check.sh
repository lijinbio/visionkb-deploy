#!/usr/bin/env bash
# Fail if a tracked file mentions a private path, user, account or node name (public-repo rule).
# Extra patterns can be added locally with VISIONKB_HYGIENE_EXTRA='pat1|pat2' (never commit them).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# Patterns are split so this file does not match itself.
pat='df''s3b|ruic''20|jinl''14|homez''vol|hpc3''-[0-9]'
[[ -n "${VISIONKB_HYGIENE_EXTRA:-}" ]] && pat="$pat|$VISIONKB_HYGIENE_EXTRA"
if git grep -nIiE "$pat" -- . ':!uv.lock'; then
  echo "hygiene-check: remove the matches above (use /path/to/..., <partition>, <account>)" >&2
  exit 1
fi
echo "hygiene-check: ok"
