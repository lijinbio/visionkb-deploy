#!/usr/bin/env bash
# End-to-end smoke test of the apptainer path on an HPC node, with two synthetic fixture releases.
#
#   tests/smoke/smoke-apptainer.sh ENV_FILE [LOG]
#
# FIXTURE_PYTHON: interpreter with pyarrow for the fixture generator (default python3).
# Optional: EXTRA_BUNDLE=/path/to/<id>.tar (another track's bundle): outer sha256 must verify; if its id
# follows the contract it is loaded, health-checked and rolled back from, else it must be refused for the id.
#
# ENV_FILE must set VISIONKB_WORK_DIR (or VISIONKB_DEPLOY_DIR), VISIONKB_RELEASES_DIR, VISIONKB_BUNDLES_DIR,
# VISIONKB_BACKUP_DIR, a dedicated VISIONKB_INSTANCE and free ports. The instance is created from scratch:
# an existing instance dir of that name is refused. Every command and its output goes to LOG.
set -euo pipefail

env_file="${1:?usage: smoke-apptainer.sh ENV_FILE [LOG]}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VK=("$repo/bin/visionkb" --env-file "$env_file")
R1=visionkb-0000.01.1
R2=visionkb-0000.01.2
log="${2:-smoke-$(date -u +%Y%m%dT%H%M%SZ).log}"
: >"$log"
pass=0
fail=0

note() { printf '\n## %s\n' "$*" | tee -a "$log"; }
run() { # run CMD...: log the command and its output; return its status
  printf '$ %s\n' "$*" >>"$log"
  local rc=0
  "$@" >>"$log" 2>&1 || rc=$?
  printf '[exit %s]\n' "$rc" >>"$log"
  return "$rc"
}
record() { # record OK DESCRIPTION [DETAIL]
  if [[ "$1" == 1 ]]; then
    pass=$((pass + 1))
    printf 'PASS %s\n' "$2" | tee -a "$log"
  else
    fail=$((fail + 1))
    printf 'FAIL %s %s\n' "$2" "${3:-}" | tee -a "$log"
  fi
}
check() { # check DESCRIPTION CMD...
  local what="$1"
  shift
  if run "$@"; then record 1 "$what"; else record 0 "$what"; fi
}
capture() { # capture CMD...: sets OUT and RC, logs both
  printf '$ %s\n' "$*" >>"$log"
  RC=0
  OUT="$("$@" 2>&1)" || RC=$?
  printf '%s\n[exit %s]\n' "$OUT" "$RC" >>"$log"
}
expect() { # expect DESCRIPTION PATTERN CMD...: success and output matching PATTERN (grep -E)
  local what="$1" pat="$2"
  shift 2
  capture "$@"
  if [[ $RC -eq 0 ]] && grep -qE -- "$pat" <<<"$OUT"; then record 1 "$what"; else record 0 "$what" "(wanted /$pat/)"; fi
}
expect_fail() { # expect_fail DESCRIPTION PATTERN CMD...: failure with output matching PATTERN
  local what="$1" pat="$2"
  shift 2
  capture "$@"
  if [[ $RC -ne 0 ]] && grep -qE -- "$pat" <<<"$OUT"; then record 1 "$what"; else record 0 "$what" "(wanted failure /$pat/)"; fi
}
setting() { "${VK[@]}" config | sed -n "s/^$1=//p"; }
last_line() { "$@" | tail -n 1; }

inst_dir="$(setting instance_dir)"
releases="$(setting VISIONKB_RELEASES_DIR)"
bundles="$(setting VISIONKB_BUNDLES_DIR)"
api_port="$(setting VISIONKB_API_PORT)"
unpacked="$(dirname "$bundles")/unpacked"
[[ ! -e "$inst_dir" ]] || {
  echo "instance dir $inst_dir exists; remove it or pick another VISIONKB_INSTANCE" >&2
  exit 2
}
api="http://127.0.0.1:$api_port/v1"
trap '"${VK[@]}" stop >>"$log" 2>&1 || true' EXIT

note "settings"
run "${VK[@]}" --version
run "${VK[@]}" config
run uname -sr

note "fixture releases (synthetic values, real IDs)"
for r in "$R1:1" "$R2:2"; do
  if [[ ! -d "$releases/${r%%:*}" ]]; then
    check "make fixture ${r%%:*}" "${FIXTURE_PYTHON:-python3}" "$repo/tests/fixtures/make_fixture_release.py" "$releases" "${r%%:*}" --variant "${r##*:}"
  fi
done

note "pull + init"
check "pull images (postgres, neo4j, api)" "${VK[@]}" pull
check "init instance" "${VK[@]}" init
expect "secrets are mode 600" '^600 600 600 600 600$' bash -c \
  "stat -c %a '$inst_dir'/secrets/{neo4j_password,pg_password,pg_dsn,api_tokens,api_token_read} | xargs"
# a curator token for the proposals write path (the default init token is read-only)
printf '%s\tread,proposals:read,proposals:write\n' "$(head -c 256 /dev/urandom | LC_ALL=C tr -dc A-Za-z0-9 | head -c 40)" \
  >>"$inst_dir/secrets/api_tokens"
# Request headers live in mode-600 files (curl -H @file) so tokens never reach argv or the log.
H_READ="$inst_dir/tmp/smoke-read.header"
H_CUR="$inst_dir/tmp/smoke-curator.header"
(
  umask 077
  printf 'Authorization: Bearer %s\n' "$(cat "$inst_dir/secrets/api_token_read")" >"$H_READ"
  printf 'Authorization: Bearer %s\n' "$(tail -n 1 "$inst_dir/secrets/api_tokens" | cut -f1)" >"$H_CUR"
)

note "verify + bundle path: export, unpack elsewhere, verify"
check "verify-release $R1" "${VK[@]}" verify-release "$R1"
rm -f "$bundles/$R2.tar" "$bundles/$R2.tar.sha256"
check "export-bundle $R2" "${VK[@]}" export-bundle "$R2" --out "$bundles"
check "sha256sum -c bundle" bash -c "cd '$bundles' && sha256sum -c '$R2.tar.sha256'"
chmod -R u+w "$unpacked" 2>/dev/null || true
rm -rf "$unpacked"
expect "unpack-bundle into a different dir" 'action: unpacked' "${VK[@]}" unpack-bundle "$bundles/$R2.tar" --dest "$unpacked"
check "verify unpacked $R2" "${VK[@]}" verify-release "$unpacked/$R2"

note "load release 1, start, health"
expect "load-release $R1" "nodes: .*'manifest': 11, 'loaded': 11" "${VK[@]}" load-release "$R1"
check "start postgres neo4j api" "${VK[@]}" start
run "${VK[@]}" status
expect "health all ok on $R1" "api: ok .*release=$R1 neo4j=ok summaries=ok postgres=ok" "${VK[@]}" health

check "no Neo4j fleet-discovery broadcasts or Fleet Manager (serving + load logs)" bash -c \
  "! grep -rlE 'Fleet discovery broadcasts have been enabled|built-in support for online monitoring through Fleet' '$inst_dir/neo4j'"
expect "fixture releases carry summaries/expr_summary.parquet (the API needs it)" 'summaries/expr_summary.parquet' \
  grep -h '"path": "summaries/expr_summary.parquet"' "$releases/$R1/manifest.json" "$releases/$R2/manifest.json"

note "readiness (/v1/ready)"
expect "GET /v1/ready is 200 with everything up" '^200$' curl -sS -o /dev/null -w '%{http_code}' "$api/ready"
check "stop neo4j only" "${VK[@]}" stop neo4j
expect "GET /v1/ready is 503 while neo4j is stopped" '^503$' curl -sS -o /dev/null -w '%{http_code}' "$api/ready"
expect "GET /v1/ready body says not_ready" '"not_ready"' curl -sS "$api/ready"
expect "GET /v1/health still answers 200 (liveness)" '^200$' curl -sS -o /dev/null -w '%{http_code}' "$api/health"
expect_fail "visionkb health fails while neo4j is stopped" 'api: NOT READY \(GET /v1/ready: 503\)' "${VK[@]}" health
check "start neo4j again" "${VK[@]}" start neo4j
ready_after=""
for _ in $(seq 1 30); do
  ready_after="$(curl -sS -o /dev/null -w '%{http_code}' "$api/ready" || true)"
  [[ "$ready_after" == 200 ]] && break
  sleep 2
done
printf '$ curl %s/ready (after neo4j start, polled up to 60 s)\n%s\n' "$api" "$ready_after" >>"$log"
if [[ "$ready_after" == 200 ]]; then record 1 "GET /v1/ready is 200 again after neo4j start"; else record 0 "GET /v1/ready after neo4j start" "($ready_after)"; fi
expect "visionkb health reports ready" 'api: ready \(GET /v1/ready: 200\)' "${VK[@]}" health

note "Cypher queries"
expect "fulltext entity_search finds RHO" '"HGNC:10012"' "${VK[@]}" cypher \
  "CALL db.index.fulltext.queryNodes('entity_search', 'rhodopsin') YIELD node RETURN node.id, node.symbol"
expect "RHO expressed_in retinal rod cell, evidence via StudyResult.edge_id" '"retinal rod cell", "Rod"' "${VK[@]}" cypher \
  "MATCH (g:Gene {symbol:'RHO'})-[r:expressed_in]->(c:Cell) MATCH (s:StudyResult {edge_id: r.id}) RETURN c.name, s.group_label, r.max_pct_expressing"
expect "subclass_of hierarchy" '"CL:0000604", "CL:0010009"' "${VK[@]}" cypher \
  "MATCH (a)-[:subclass_of]->(b) WHERE a.id = 'CL:0000604' RETURN a.id, b.id"
expect_fail "graph is read-only" '[Rr]ead-only|read only' "${VK[@]}" cypher "CREATE (:Probe {x: 1})"

note "API (bearer token)"
expect "API rejects a missing token (401)" '^401$' curl -sS -o /dev/null -w '%{http_code}' "$api/entities/search?q=RHO"
expect "GET /v1/entities/search?q=RHO" '"HGNC:10012"' curl -fsS -H "@$H_READ" "$api/entities/search?q=RHO"
expect "GET /v1/relationships?subject=HGNC:10012" '"biolink:expressed_in"' curl -fsS -H "@$H_READ" \
  "$api/relationships?subject=HGNC:10012"
expect "GET /v1/atlas/expression?genes=RHO" '"pseudobulk_cp10k"' curl -fsS -H "@$H_READ" "$api/atlas/expression?genes=RHO"
body='{"edge":{"subject":"HGNC:9937","predicate":"biolink:expressed_in","object":"CL:0000573","knowledge_level":"observation","agent_type":"data_analysis_pipeline"},"run_id":"smoke-test","visibility":"lab"}'
expect "POST /v1/proposals (curator token)" '"proposed"' curl -fsS -H "@$H_CUR" -H 'Content-Type: application/json' \
  -d "$body" "$api/proposals"
expect "POST /v1/proposals with the read token is refused (403)" '^403$' curl -sS -o /dev/null -w '%{http_code}' \
  -H "@$H_READ" -H 'Content-Type: application/json' -d "$body" "$api/proposals"

note "backup"
capture "${VK[@]}" backup
backup_dir="$(tail -n 1 <<<"$OUT")"
if [[ $RC -eq 0 && -s "$backup_dir/proposals.pgdump" ]]; then record 1 "backup wrote proposals.pgdump"; else record 0 "backup"; fi
expect "proposals in DB at backup time: 1" '"total": ?1' curl -fsS -H "@$H_CUR" "$api/proposals"

note "load release 2 from the unpacked bundle (the served stack restarts onto it)"
expect "load-release $R2 --from <unpacked bundle>" "nodes: .*'manifest': 13, 'loaded': 13" \
  "${VK[@]}" load-release "$R2" --from "$unpacked"
expect "health on $R2" "api: ok .*release=$R2 neo4j=ok summaries=ok postgres=ok" "${VK[@]}" health
expect "PDE6B present in $R2" '"PDE6B"' "${VK[@]}" cypher "MATCH (g:Gene {id:'HGNC:8786'}) RETURN g.symbol"

note "rollback"
check "rollback (to previous)" "${VK[@]}" rollback
expect "health back on $R1" "api: ok .*release=$R1 neo4j=ok" "${VK[@]}" health
expect "PDE6B absent in $R1" '^0$' last_line "${VK[@]}" cypher "MATCH (g:Gene {id:'HGNC:8786'}) RETURN count(g)"
expect "node count back to 11" '^11$' last_line "${VK[@]}" cypher "MATCH (n) RETURN count(n)"
check "rollback $R2 (by id)" "${VK[@]}" rollback "$R2"
expect "health on $R2 again" "api: ok .*release=$R2 neo4j=ok" "${VK[@]}" health
expect_fail "rollback to an unloaded release is refused" 'not loaded' "${VK[@]}" rollback visionkb-0000.01.9
expect_fail "re-loading a loaded release is refused without --force" 'already loaded' "${VK[@]}" load-release "$R1"
run "${VK[@]}" releases

if [[ -n "${EXTRA_BUNDLE:-}" ]]; then
  note "extra bundle: $(basename "$EXTRA_BUNDLE")"
  check "outer sha256 of the extra bundle" "$(setting VISIONKB_PYTHON)" "$repo/src/visionkb_deploy/bundle.py" verify-bundle "$EXTRA_BUNDLE"
  xid="$(basename "$EXTRA_BUNDLE" .tar)"
  if [[ "$xid" =~ ^visionkb-[0-9]{4}\.[0-9]{2}\.[0-9]+$ ]]; then
    expect "load-release --bundle $xid" 'current=' "${VK[@]}" load-release "$xid" --bundle "$EXTRA_BUNDLE"
    expect "health on $xid" "api: ok .*release=$xid neo4j=ok summaries=ok postgres=ok" "${VK[@]}" health
    check "rollback from $xid" "${VK[@]}" rollback
  else
    expect_fail "extra bundle with a non-contract release id ($xid) is refused" 'invalid (release id|kg_release)' \
      "${VK[@]}" load-release "$xid" --bundle "$EXTRA_BUNDLE"
    expect_fail "unpack-bundle refuses it too (nothing half-unpacked)" 'invalid kg_release' \
      "${VK[@]}" unpack-bundle "$EXTRA_BUNDLE" --dest "$unpacked-extra"
    check "no partial unpack left" test ! -e "$unpacked-extra/$xid.partial"
  fi
fi

note "restore"
# same edge, different run_id (the API de-duplicates on run_id + edge)
check "second proposal" curl -fsS -o /dev/null -H "@$H_CUR" -H 'Content-Type: application/json' \
  -d "${body/smoke-test/smoke-test-2}" "$api/proposals"
expect "proposals before restore: 2" '"total": ?2' curl -fsS -H "@$H_CUR" "$api/proposals"
check "restore backup" "${VK[@]}" restore "$backup_dir" --yes
expect "proposals after restore: 1" '"total": ?1' curl -fsS -H "@$H_CUR" "$api/proposals"

note "stop"
check "stop" "${VK[@]}" stop
expect "all stopped" 'postgres +stopped' "${VK[@]}" status
trap - EXIT
rm -f "$H_READ" "$H_CUR"

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail" | tee -a "$log"
((fail == 0))
