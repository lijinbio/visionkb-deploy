#!/usr/bin/env bash
# End-to-end smoke test of the apptainer path on an HPC node, with two synthetic fixture releases.
#
#   tests/smoke/smoke-apptainer.sh ENV_FILE [LOG]
#
# FIXTURE_PYTHON: interpreter with pyarrow for the fixture generator (default python3).
# Optional: EXTRA_BUNDLE=/path/to/<id>.tar (another track's bundle): outer sha256 must verify; if its id
# follows the contract it is loaded (pinned to its own sha256), health-checked and rolled back from, else it
# must be refused for the id.
# The visionkb-kg MCP server image (VISIONKB_MCP_IMAGE) is pulled and run over stdio against the served API
# (tests/smoke/mcp_stdio_check.py); SMOKE_MCP=0 skips that section (it is then reported as SKIPPED).
# With `web` in VISIONKB_SERVICES the web home page is started with the stack (canary ANTHROPIC_* variables in the
# caller's environment must not reach it) and checked: /healthz, /readyz with 8 MCP tools, CSP, access-code login,
# the KG proxy (search, no /proposals, read-only), /api/models without a key. Without web that section is SKIPPED.
# Verified store cache: every id-checked load writes a dump; ensure-loaded / rollback restore from it; ID_CHECK=always,
# a broken dump sha256 and load-release --force take the full path. In-job restart: request-restart + process-requests
# (as the sbatch job runs it), incl. switching the web image to another digest-pinned SIF and back
# (SMOKE_WEB_ALT_IMAGE, default the visionkb-web 0.0.3 digest = the v0.1.6 pin, if its SIF is in the images dir).
# Stale postgres lock: the postgres instance is SIGKILLed (as after a preemption); start refuses without an owner
# record and while the owner job runs, and moves the lock aside when the owner (SMOKE_FINISHED_JOB: a finished job id,
# optional; then this job) no longer runs it. Fast failure: a throwaway instance <instance>-ff whose postgres exits at
# once must fail well before VISIONKB_START_TIMEOUT (port SMOKE_FF_PG_PORT, default PG port + 7).
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
store_dir="$(setting VISIONKB_STORE_DIR)"
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

note "bundle sha pin (VISIONKB_KG_BUNDLE_SHA256; per command, the environment wins over versions.env)"
expect "versions.env pin applies to its release visionkb-2026.11.0 only" \
  '^VISIONKB_KG_RELEASE=visionkb-2026\.11\.0 VISIONKB_KG_BUNDLE_SHA256=[0-9a-f]{64}$' \
  bash -c "\"\$@\" config | grep -E '^VISIONKB_KG_(RELEASE|BUNDLE_SHA256)=' | xargs" _ "${VK[@]}"
sha2="$(sha256sum "$bundles/$R2.tar" | cut -d' ' -f1)"
bad="$(printf 'a%.0s' {1..64})"
chmod -R u+w "$unpacked-pin" "$unpacked-pin2" 2>/dev/null || true
rm -rf "$unpacked-pin" "$unpacked-pin2"
expect_fail "unpack-bundle: pinned $R2 with another sha256 is refused" "!= pinned VISIONKB_KG_BUNDLE_SHA256 $bad" \
  env VISIONKB_KG_RELEASE="$R2" VISIONKB_KG_BUNDLE_SHA256="$bad" "${VK[@]}" unpack-bundle "$bundles/$R2.tar" --dest "$unpacked-pin"
check "pin refusal: nothing unpacked" test ! -e "$unpacked-pin/$R2" -a ! -e "$unpacked-pin/$R2.partial"
expect "unpack-bundle: pinned $R2 with its own sha256" 'action: unpacked' \
  env VISIONKB_KG_RELEASE="$R2" VISIONKB_KG_BUNDLE_SHA256="$sha2" "${VK[@]}" unpack-bundle "$bundles/$R2.tar" --dest "$unpacked-pin"
expect "a pin for another release ($R1) does not affect the $R2 bundle" 'action: unpacked' \
  env VISIONKB_KG_RELEASE="$R1" VISIONKB_KG_BUNDLE_SHA256="$bad" "${VK[@]}" unpack-bundle "$bundles/$R2.tar" --dest "$unpacked-pin2"
chmod -R u+w "$unpacked-pin" "$unpacked-pin2" 2>/dev/null || true
rm -rf "$unpacked-pin" "$unpacked-pin2"

note "node-local Neo4j store"
expect "store dir is on local disk (not BeeGFS/NFS/Lustre)" '^store_fs=(xfs|ext2/ext3|ext4|tmpfs|btrfs|zfs|overlayfs)$' \
  bash -c "\"\$@\" config | grep '^store_fs='" _ "${VK[@]}"
expect_fail "a store on the network filesystem is refused" 'network filesystem' \
  env VISIONKB_STORE_DIR="$inst_dir/network-store-test" "${VK[@]}" load-release "$R1"
check "nothing was written for the refused store" test ! -e "$inst_dir/network-store-test"

note "load release 1, start, health"
expect "load-release $R1 (counts)" "nodes: .*'manifest': 11, 'loaded': 11" "${VK[@]}" load-release "$R1"
expect "load-release $R1: every node id and relationship key matched the CSVs" '"id_check":"ok"' \
  cat "$inst_dir/neo4j/loaded/$R1/LOADED.json"
dumps="$inst_dir/neo4j/dumps"
expect "dump of $R1 written after the id-checked load (DUMP.json)" "\"kg_release\":\"$R1\".*\"nodes\":11,\"relationships\":10.*\"id_check\":\"ok\".*\"dump_sha256\":\"[0-9a-f]{64}\"" \
  cat "$dumps/$R1/DUMP.json"
check "dump sha256 verifies (sha256sum -c)" bash -c "cd '$dumps/$R1' && sha256sum -c '$R1.dump.sha256'"
expect "dump dir mode 700, files mode 600" '^700 600 600 600$' bash -c \
  "stat -c %a '$dumps/$R1' '$dumps/$R1/$R1.dump' '$dumps/$R1/$R1.dump.sha256' '$dumps/$R1/DUMP.json' | xargs"
expect "releases: the dump of $R1 matches its record" "dump: matches" "${VK[@]}" releases
check "store is node-local, record is persistent" test -s "$store_dir/neo4j/releases/$R1/LOADED.json" -a \
  -s "$inst_dir/neo4j/loaded/$R1/SOURCE"
services="$(setting VISIONKB_SERVICES)"
web_on=0
[[ " $services " == *" web "* ]] && web_on=1
canary=(env ANTHROPIC_API_KEY=sk-ant-smoke-canary-0001 APPTAINERENV_ANTHROPIC_API_KEY=sk-ant-smoke-canary-0002
  SINGULARITYENV_ANTHROPIC_API_KEY=sk-ant-smoke-canary-0003)
capture "${canary[@]}" "${VK[@]}" start
order="$(grep -oE '^visionkb: start (postgres|neo4j|api|web)$' <<<"$OUT" | awk '{print $3}' | xargs)"
if [[ $RC -eq 0 && "$order" == "$(xargs <<<"$(for s in postgres neo4j api web; do [[ " $services " == *" $s "* ]] && echo "$s"; done)")" ]]; then
  record 1 "start ($services): in order $order"
else record 0 "start ($services)" "(order: $order, rc $RC)"; fi
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

note "id check catches a store that differs from the CSVs"
tampered="$store_dir/tmp/tampered-$R2"
rm -rf "$tampered"
check "expected ids of $R2" "$(setting VISIONKB_PYTHON)" "$repo/src/visionkb_deploy/bundle.py" expected-ids "$unpacked/$R2" --out "$tampered"
# simulate one garbled node id
sed -i 's/"HGNC:8786"/"HGNC:878X"/' "$tampered/nodes.ids" && LC_ALL=C sort -o "$tampered/nodes.ids" "$tampered/nodes.ids"
expect_fail "load with a mismatching id set fails (id check FAILED)" 'id check FAILED' \
  "${VK[@]}" load-release "$R2" --from "$unpacked" --expected-ids "$tampered"
expect "failed load changed no pointer and published no store" "^current: +$R1\$" bash -c "\"\$@\" releases | head -n 1" _ "${VK[@]}"
check "no published store for the failed load" test ! -e "$store_dir/neo4j/releases/$R2/LOADED.json"
rm -rf "$tampered"

note "imported totals must equal the manifest counts (contracts v0.8 section 13)"
R3=visionkb-0000.01.3
badrel="$store_dir/tmp/bad-counts"
rm -rf "$badrel"
check "fixture $R3 for the count test" "${FIXTURE_PYTHON:-python3}" "$repo/tests/fixtures/make_fixture_release.py" "$badrel" "$R3"
# manifest claims one node more than the CSVs hold (consistent sums; manifest.json itself is not checksummed)
"${FIXTURE_PYTHON:-python3}" - "$badrel/$R3/manifest.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p))
m["counts"]["nodes_total"] += 1; m["counts"]["nodes_by_category"]["biolink:Gene"] += 1
json.dump(m, open(p, "w"), indent=2)
PY
expect_fail "load fails when imported totals differ from the manifest" 'imported totals differ from the manifest counts' \
  "${VK[@]}" load-release "$R3" --from "$badrel"
check "count failure: no record and no published store" test ! -e "$inst_dir/neo4j/loaded/$R3" -a ! -e "$store_dir/neo4j/releases/$R3/LOADED.json"
expect "count failure: pointers unchanged" "^current: +$R1\$" bash -c "\"\$@\" releases | head -n 1" _ "${VK[@]}"
chmod -R u+w "$badrel" "$store_dir/neo4j/releases/$R3.partial" 2>/dev/null || true
rm -rf "$badrel" "$store_dir/neo4j/releases/$R3.partial"

note "load-release --bundle refuses the pinned release with another sha256"
ptr_before="$("${VK[@]}" releases | grep -E '^(current|previous):' | xargs)"
# the id-check test above keeps $R2.partial for inspection; the refused load must not touch it
partial_before="$(stat -c %Y "$store_dir/neo4j/releases/$R2.partial" 2>/dev/null || echo none)"
expect_fail "load-release --bundle: pinned $R2 with another sha256 is refused before import" \
  "!= pinned VISIONKB_KG_BUNDLE_SHA256 $bad" \
  env VISIONKB_KG_RELEASE="$R2" VISIONKB_KG_BUNDLE_SHA256="$bad" "${VK[@]}" load-release "$R2" --bundle "$bundles/$R2.tar"
check "pin refusal: no unpack, no load record, no published store" test ! -e "$inst_dir/bundles/$R2" -a \
  ! -e "$inst_dir/neo4j/loaded/$R2" -a ! -e "$store_dir/neo4j/releases/$R2"
expect "pin refusal: no import ran (the kept $R2.partial is untouched: $partial_before)" "^${partial_before}\$" \
  bash -c "stat -c %Y '$store_dir/neo4j/releases/$R2.partial' 2>/dev/null || echo none"
expect "pin refusal: pointers unchanged" "^${ptr_before//./\\.}\$" bash -c "\"\$@\" releases | grep -E '^(current|previous):' | xargs" _ "${VK[@]}"

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

note "new allocation: node-local stores are gone"
cur_before="$(bash -c "\"\$@\" releases | sed -n 's/^current: *//p'" _ "${VK[@]}")"
prev_before="$(bash -c "\"\$@\" releases | sed -n 's/^previous: *//p'" _ "${VK[@]}")"
check "stop" "${VK[@]}" stop
chmod -R u+w "$store_dir" 2>/dev/null || true
rm -rf "$store_dir"
expect_fail "start refuses: current store missing, tells to run ensure-loaded" 'ensure-loaded' "${VK[@]}" start
expect "ensure-loaded re-imports the current release ($cur_before) from its record" "re-importing $cur_before" \
  "${VK[@]}" ensure-loaded
if grep -qE "ensure-loaded $cur_before: restored from the verified dump in [0-9]+ s" <<<"$OUT"; then
  record 1 "ensure-loaded used the verified dump of $cur_before ($(grep -oE 'restored from the verified dump in [0-9]+ s' <<<"$OUT"))"
else record 0 "ensure-loaded via the dump of $cur_before"; fi
check "start after ensure-loaded" "${canary[@]}" "${VK[@]}" start
expect "health on $cur_before after re-import" "api: ok .*release=$cur_before neo4j=ok summaries=ok postgres=ok" "${VK[@]}" health
expect "rollback re-imports the previous release ($prev_before) whose store is missing" "re-importing $prev_before" \
  "${VK[@]}" rollback
if grep -qE "restored from the verified dump in [0-9]+ s" <<<"$OUT"; then
  record 1 "rollback re-import used the verified dump of $prev_before"
else record 0 "rollback re-import via the dump of $prev_before"; fi
expect "health on $prev_before" "api: ok .*release=$prev_before neo4j=ok" "${VK[@]}" health

note "verified store cache: VISIONKB_ID_CHECK=always, broken dump sha256, load-release --force, restore timing"
rc_cur="$("${VK[@]}" releases | sed -n 's/^current: *//p')"
rc_prev="$("${VK[@]}" releases | sed -n 's/^previous: *//p')"
dump_created() { sed -n 's/.*"created_utc":"\([^"]*\)".*/\1/p' "$dumps/$1/DUMP.json" 2>/dev/null; }
check "stop (the served store is replaced below)" "${VK[@]}" stop
c0="$(dump_created "$rc_cur")"
sleep 1
chmod -R u+w "$store_dir" 2>/dev/null || true
rm -rf "$store_dir"
expect "VISIONKB_ID_CHECK=always: full load with the id check, no restore" "VISIONKB_ID_CHECK=always: full load" \
  env VISIONKB_ID_CHECK=always "${VK[@]}" ensure-loaded
t_full="$(grep -oE "full load in [0-9]+ s" <<<"$OUT" | grep -oE '[0-9]+' || true)"
if ! grep -q 'restoring from the dump' <<<"$OUT" && grep -q 'id check ok' "$inst_dir/neo4j/logs/load-$rc_cur.log" &&
  [[ "$(dump_created "$rc_cur")" != "$c0" ]]; then
  record 1 "ID_CHECK=always: full path ($t_full s incl. a new dump), id check ok, dump rewritten"
else record 0 "ID_CHECK=always full path"; fi
chmod -R u+w "$store_dir" 2>/dev/null || true
rm -rf "$store_dir"
printf '%064d  %s.dump\n' 0 "$rc_cur" >"$dumps/$rc_cur/$rc_cur.dump.sha256"
expect "broken dump sha256: detected, full load instead" "dump sha256 mismatch .*full load" "${VK[@]}" ensure-loaded
check "the full load rewrote a valid dump" bash -c "cd '$dumps/$rc_cur' && sha256sum -c '$rc_cur.dump.sha256'"
chmod -R u+w "$store_dir" 2>/dev/null || true
rm -rf "$store_dir"
expect "ensure-loaded restores $rc_cur from the dump" "restored from the verified dump in [0-9]+ s" "${VK[@]}" ensure-loaded
t_dump="$(grep -oE "restored from the verified dump in [0-9]+ s" <<<"$OUT" | grep -oE '[0-9]+' || true)"
expect "restored store: LOADED.json source dump, id_check dump" '"id_check":"dump".*"source":"dump"' \
  cat "$store_dir/neo4j/releases/$rc_cur/LOADED.json"
printf 'TIMING ensure-loaded %s (fixture): full path %s s (incl. dump), from dump %s s\n' "$rc_cur" "${t_full:-?}" "${t_dump:-?}" | tee -a "$log"
check "start on the restored store" "${canary[@]}" "${VK[@]}" start
expect "health on the restored $rc_cur" "api: ok .*release=$rc_cur neo4j=ok summaries=ok postgres=ok" "${VK[@]}" health
if [[ -n "$rc_prev" && "$rc_prev" != none ]]; then
  p0="$(dump_created "$rc_prev")"
  sleep 1
  expect "load-release --force $rc_prev: full load, the old dump is replaced (never reused)" \
    "removed the dump of $rc_prev \(replaced by this load\)" "${VK[@]}" load-release "$rc_prev" --force --no-activate
  if ! grep -q 'restoring from the dump' <<<"$OUT" && [[ -n "$(dump_created "$rc_prev")" && "$(dump_created "$rc_prev")" != "$p0" ]]; then
    record 1 "--force: no restore, new dump of $rc_prev"
  else record 0 "--force dump replacement"; fi
fi

if [[ -n "${EXTRA_BUNDLE:-}" ]]; then
  note "extra bundle: $(basename "$EXTRA_BUNDLE")"
  check "outer sha256 of the extra bundle" "$(setting VISIONKB_PYTHON)" "$repo/src/visionkb_deploy/bundle.py" verify-bundle "$EXTRA_BUNDLE"
  xid="$(basename "$EXTRA_BUNDLE" .tar)"
  if [[ "$xid" =~ ^visionkb-[0-9]{4}\.[0-9]{2}\.[0-9]+$ ]]; then
    xsha="$(sha256sum "$EXTRA_BUNDLE" | cut -d' ' -f1)"
    # as the default release would be loaded on the Eye server: pinned to its own sha256
    expect "load-release --bundle $xid, pinned to its sha256 ${xsha:0:12}..." 'current=' \
      env VISIONKB_KG_RELEASE="$xid" VISIONKB_KG_BUNDLE_SHA256="$xsha" "${VK[@]}" load-release "$xid" --bundle "$EXTRA_BUNDLE"
    # this load's own output (OUT): totals equal and no count warning
    if grep -qE "^nodes: \{'manifest': ([0-9]+), 'loaded': \1\}" <<<"$OUT" &&
      grep -qE "^relationships: \{'manifest': ([0-9]+), 'loaded': \1\}" <<<"$OUT" && ! grep -qiE 'warning|differ' <<<"$OUT"; then
      record 1 "imported totals of $xid equal its manifest nodes_total/edges_total, no count warning"
    else
      record 0 "imported totals of $xid vs manifest"
    fi
    expect "GET /v1/release of $xid lists its known issues" '"KI-1"' curl -fsS -H "@$H_READ" "$api/release"
    expect "health on $xid" "api: ok .*release=$xid neo4j=ok summaries=ok postgres=ok" "${VK[@]}" health
    check "rollback from $xid" "${VK[@]}" rollback
    expect "dumps kept for the current and previous release only" \
      "^$(printf '%s\n' "$("${VK[@]}" releases | sed -n 's/^current: *//p')" "$("${VK[@]}" releases | sed -n 's/^previous: *//p')" | LC_ALL=C sort | xargs)\$" \
      bash -c "ls '$dumps' | LC_ALL=C sort | xargs"
  else
    expect_fail "extra bundle with a non-contract release id ($xid) is refused" 'invalid (release id|kg_release)' \
      "${VK[@]}" load-release "$xid" --bundle "$EXTRA_BUNDLE"
    expect_fail "unpack-bundle refuses it too (nothing half-unpacked)" 'invalid kg_release' \
      "${VK[@]}" unpack-bundle "$EXTRA_BUNDLE" --dest "$unpacked-extra"
    check "no partial unpack left" test ! -e "$unpacked-extra/$xid.partial"
  fi
fi

note "AiScientist: visionkb-kg MCP server over stdio (apptainer exec, as in docs/aiscientist.md)"
if [[ "${SMOKE_MCP:-1}" == 1 ]]; then
  check "pull mcp (visionkb-kg MCP server image, by digest)" "${VK[@]}" pull mcp
  mcp_sif="$(setting mcp_sif)"
  if ! command -v apptainer >/dev/null 2>&1; then
    set +u
    # shellcheck disable=SC1090
    source "$(setting VISIONKB_MODULES_INIT)" && module load "$(setting VISIONKB_APPTAINER_MODULE)"
    set -u
  fi
  served="$("${VK[@]}" releases | sed -n 's/^current: *//p')"
  mcp_py="$(setting VISIONKB_PYTHON)"
  mcp_run=(apptainer exec --containall --no-home --cleanenv --pwd /
    -B "$inst_dir/secrets/api_token_read:/run/secrets/visionkb_token:ro"
    --env "VISIONKB_API_URL=$api" --env VISIONKB_API_TOKEN_FILE=/run/secrets/visionkb_token
    "$mcp_sif" visionkb-kg-mcp)
  expect "MCP stdio: initialize + the 8 visionkb-kg tools" \
    '"tools": \["find_datasets", "get_entity", "get_evidence", "get_gene_set", "get_relationships", "get_release", "query_atlas_expression", "search_entities"\]' \
    "$mcp_py" "$repo/tests/smoke/mcp_stdio_check.py" -- "${mcp_run[@]}"
  mcp_out="$OUT"
  if grep -qF "\"get_release\": {\"kg_release\": \"$served\", \"ready\": true, \"status\": \"ok\"}" <<<"$mcp_out"; then
    record 1 "MCP get_release: status ok, ready, kg_release = served $served"
  else record 0 "MCP get_release on $served"; fi
  if grep -qE '"search_entities": \{"error": null, "ids": \["HGNC:10012"' <<<"$mcp_out"; then
    record 1 "MCP search_entities(q=RHO): HGNC:10012 first"
  else record 0 "MCP search_entities(q=RHO)"; fi
  if grep -qE '"get_relationships": \{"has_next_offset": true, "next_offset": 1, "returned": 1, "status": "ok", "total": [2-9]' <<<"$mcp_out" &&
    grep -qE '"get_relationships_page2": \{"new_edges": true, "offset": 1, "returned": 1, "status": "ok"\}' <<<"$mcp_out"; then
    record 1 "MCP get_relationships(object=CL:0000604, limit=1): page 2 at paging.next_offset returns a new edge"
  else record 0 "MCP get_relationships paging by next_offset"; fi
  if [[ "$(grep -oE '"max_result_chars": [0-9]+' <<<"$mcp_out" | grep -oE '[0-9]+$')" -le 24000 ]]; then
    record 1 "MCP results within 24,000 characters"
  else record 0 "MCP result size"; fi
  expect "MCP without a token file: unauthorized error result, no data" '"search_entities": \{"error": "unauthorized", "ids": \[\]' \
    "$mcp_py" "$repo/tests/smoke/mcp_stdio_check.py" --no-token -- apptainer exec --containall --no-home --cleanenv --pwd / \
    --env "VISIONKB_API_URL=$api" "$mcp_sif" visionkb-kg-mcp
else
  printf 'SKIPPED MCP section (SMOKE_MCP=0)\n' | tee -a "$log"
fi

note "web home page (visionkb-web, service web)"
http_body() { # http_body CURL_ARGS...: prints "<status> <body>"
  local f rc=0
  f="$(mktemp)"
  curl -sS -o "$f" -w '%{http_code} ' "$@" || rc=$?
  cat "$f"
  rm -f "$f"
  return "$rc"
}
web_env_scan() { # count ANTHROPIC/canary entries in the environment of every process of the web instance
  # shellcheck disable=SC2016 # expanded by the shell inside the instance
  (cd / && apptainer exec --cleanenv "instance://visionkb-$(setting VISIONKB_INSTANCE)-web" sh -c \
    'for f in /proc/[0-9]*/environ; do tr "\0" "\n" <"$f" 2>/dev/null; done') | grep -ciE 'anthropic|canary' || true
}
web_log_scan() { # the app logs 'ignored and removed environment variables: ...' if any ANTHROPIC_* reached it
  cat "${APPTAINER_INSTANCE_LOGS:-$HOME/.apptainer/instances/logs}"/*/"$(id -un)"/"visionkb-$(setting VISIONKB_INSTANCE)-web".{out,err} \
    2>/dev/null | grep -ciE 'ignored and removed|canary' || true
}
if ((web_on)); then
  web="http://127.0.0.1:$(setting VISIONKB_WEB_PORT)"
  served="$("${VK[@]}" releases | sed -n 's/^current: *//p')"
  codes="$inst_dir/secrets/web_access_codes"
  expect "web /healthz 200" '"status": ?"ok"' curl -fsS "$web/healthz"
  expect "web /readyz 200 with the 8 MCP tools on $served" "\"kg_release\": ?\"$served\".*\"n_tools\": ?8" curl -fsS "$web/readyz"
  expect "visionkb health: web ready, 8 MCP tools" 'web: ready \(GET /readyz: 200; mcp tools 8' "${VK[@]}" health
  expect "CSP header on the page" "content-security-policy: default-src 'self'; script-src 'self'.*frame-ancestors 'none'" \
    curl -fsS -D - -o /dev/null "$web/" # GET: the app answers HEAD with 405
  expect "nosniff header on the page" 'x-content-type-options: nosniff' curl -fsS -D - -o /dev/null "$web/" # GET: the app answers HEAD with 405
  expect "KG proxy without login: 401 unauthorized" '^401 .*"unauthorized"' http_body "$web/api/kg/entities/search?q=RHO"
  expect "access codes file: mode 600, one code of >= 16 characters" '^600 [1-9][0-9]* (1[6-9]|[2-9][0-9])$' bash -c \
    "printf '%s %s %s' \"\$(stat -c %a '$codes')\" \"\$(grep -cv '^#' '$codes')\" \"\$(grep -v '^#' '$codes' | head -n 1 | tr -d '\n' | wc -c)\""
  # the access code goes into a mode-600 body file (never argv or the log); the session cookie into a mode-600 jar
  W_BODY="$inst_dir/tmp/smoke-web-login.json"
  W_BAD="$inst_dir/tmp/smoke-web-bad.json"
  W_JAR="$inst_dir/tmp/smoke-web.cookies"
  (
    umask 077
    printf '{"code": "%s"}' "$(grep -v '^#' "$codes" | head -n 1)" >"$W_BODY"
    printf '{"code": "not-the-right-code-0000"}' >"$W_BAD"
    : >"$W_JAR"
  )
  expect "login without the X-VisionKB-Web header: 403 csrf" '^403 .*"csrf"' \
    http_body -H 'Content-Type: application/json' --data-binary "@$W_BODY" "$web/api/session"
  expect "login with a wrong code: 401 invalid_code" '^401 .*"invalid_code"' \
    http_body -H 'X-VisionKB-Web: 1' -H 'Content-Type: application/json' --data-binary "@$W_BAD" "$web/api/session"
  expect "login with the code from <instance>/secrets/web_access_codes: HttpOnly SameSite=Strict cookie" \
    'set-cookie: [^ ]+=.*httponly.*samesite=strict' bash -c "curl -fsS -D - -o /dev/null -c '$W_JAR' -H 'X-VisionKB-Web: 1' \
      -H 'Content-Type: application/json' --data-binary @'$W_BODY' '$web/api/session' | tr 'A-Z' 'a-z' | sed 's/=[^;]*;/=<redacted>;/'"
  expect "proxy search RHO -> HGNC:10012 (served $served)" '"id": ?"HGNC:10012"' \
    curl -fsS -b "$W_JAR" "$web/api/kg/entities/search?q=RHO&limit=3"
  expect "proxy /api/kg/proposals is not allowed: 404" '^404 .*"not_allowed"' http_body -b "$W_JAR" "$web/api/kg/proposals"
  expect "proxy is read-only: POST gives 405" '^405 ' \
    http_body -b "$W_JAR" -H 'X-VisionKB-Web: 1' -X POST "$web/api/kg/release"
  expect "/api/models without a Claude key: 401 invalid_key (no key server-side)" '^401 .*"invalid_key"' \
    http_body -b "$W_JAR" "$web/api/models"
  if ! command -v apptainer >/dev/null 2>&1; then
    set +u
    # shellcheck disable=SC1090
    source "$(setting VISIONKB_MODULES_INIT)" && module load "$(setting VISIONKB_APPTAINER_MODULE)"
    set -u
  fi
  # canaries were in the caller's environment of `start`; none may reach the web instance
  expect "no ANTHROPIC_* / canary in any process environment of the web instance" '^0$' web_env_scan
  expect "web log: no 'ignored and removed environment variables' (nothing Anthropic reached the app)" '^0$' web_log_scan
  rm -f "$W_BODY" "$W_BAD" "$W_JAR"
else
  printf 'SKIPPED web section (web not in VISIONKB_SERVICES)\n' | tee -a "$log"
fi

note "in-job restart: request-restart + process-requests (what slurm/visionkb.sbatch runs every poll)"
if ((web_on)); then
  pr_opt=()
  [[ -n "${SLURM_JOB_ID:-}" ]] || pr_opt=(--local)
  alt="${SMOKE_WEB_ALT_IMAGE:-ghcr.io/lijinbio/visionkb-web:0.0.3@sha256:a65fd8522f231756c3c5a308485e616c5b0f8cb5d78e33f8552ac2dd9cdccba4}"
  cfg_web="$(setting VISIONKB_WEB_IMAGE)"
  # SIF name as `visionkb pull` writes it: <name>_<tag>_<digest12>.sif
  alt_sif="$(setting VISIONKB_IMAGES_DIR)/$(bash -c 'source "$1/libexec/visionkb-env.sh"; read -r n t d <<<"$(image_parts "$2")"
    s="_${d#sha256:}"; printf "%s_%s%s.sif" "${n##*/}" "${t/#-/latest}" "${s:0:13}"' _ "$repo" "$alt")"
  expect_fail "request-restart refuses a tag-only image ref" "not digest-pinned" \
    env VISIONKB_WEB_IMAGE=ghcr.io/lijinbio/visionkb-web:0.0.2 "${VK[@]}" request-restart web
  restart_web() { # restart_web IMAGE LABEL: request (from "another clone" = env override) + the job's processing
    local img="$1" label="$2" t0 id res wall
    t0=$SECONDS
    capture env VISIONKB_WEB_IMAGE="$img" "${VK[@]}" request-restart web
    id="$(tail -n 1 <<<"$OUT")"
    capture "${VK[@]}" process-requests "${pr_opt[@]}"
    res="$inst_dir/control/results/$id.result"
    wall=$((SECONDS - t0))
    if grep -qx 'status=ok' "$res" 2>/dev/null && grep -qx "image_web=$img" "$res"; then
      record 1 "request-restart web ($label): ok, $(grep '^seconds=' "$res") (stop $(sed -n 's/^stop_seconds=//p' "$res") s, start $(sed -n 's/^start_seconds=//p' "$res") s), web_readyz $(sed -n 's/^web_readyz=//p' "$res"); wall ${wall} s"
      printf 'TIMING request-restart web (%s): request->result %s s, job-side %s s\n' "$label" "$wall" "$(sed -n 's/^seconds=//p' "$res")" | tee -a "$log"
    else
      record 0 "request-restart web ($label)" "($(tr '\n' ' ' <"$res" 2>/dev/null))"
    fi
  }
  if [[ -f "$alt_sif" && "$(tr -d '[:space:]' <"$alt_sif.ref" 2>/dev/null)" == "$alt" && "$alt" != "$cfg_web" ]]; then
    restart_web "$alt" "to ${alt%@*}"
    alt_ver="${alt%@*}"
    alt_ver="${alt_ver##*:}"
    expect "/healthz reports visionkb-web $alt_ver" "\"version\": ?\"$alt_ver\"" curl -fsS "$web/healthz"
    expect "web /readyz 200 after the switch" '"n_tools": ?8' curl -fsS "$web/readyz"
    restart_web "$cfg_web" "back to ${cfg_web%@*}"
    cfg_ver="${cfg_web%@*}"
    cfg_ver="${cfg_ver##*:}"
    expect "/healthz reports visionkb-web $cfg_ver again" "\"version\": ?\"$cfg_ver\"" curl -fsS "$web/healthz"
    expect "restarted web instance: no ANTHROPIC_* / canary in any process environment" '^0$' web_env_scan
  else
    printf 'SKIPPED web image switch (no SIF for %s in the images dir)\n' "$alt" | tee -a "$log"
    restart_web "$cfg_web" "same image"
  fi
  # a forged request with a SIF outside the images dir: rejected by the job, nothing restarted
  fid="smoke-forged-$$"
  (umask 077 && printf '%s\n' "id=$fid" "created_epoch=$(date +%s)" "deploy_version=0" "requested_by=smoke" "services=web" \
    "image_web=$cfg_web" "sif_web=/etc/passwd" >"$inst_dir/control/requests/$fid.req")
  capture "${VK[@]}" process-requests "${pr_opt[@]}"
  expect "forged request (SIF outside the images dir) rejected" 'is not the images dir path' cat "$inst_dir/control/results/$fid.result"
  expect "control dir mode 700" '^700$' stat -c %a "$inst_dir/control"
  # all four services in one request (keys image_neo4j / sif_neo4j contain a digit); --wait while the "job" processes it
  (sleep 3 && "${VK[@]}" process-requests "${pr_opt[@]}" >>"$log" 2>&1) &
  t0=$SECONDS
  capture "${VK[@]}" request-restart --wait --timeout 1200 postgres neo4j api web
  wait
  if [[ $RC -eq 0 ]] && grep -qx 'status=ok' <<<"$OUT" && grep -qx 'services=postgres neo4j api web' <<<"$OUT" &&
    grep -qx 'web_readyz=200' <<<"$OUT" && grep -qx 'api_ready=200' <<<"$OUT"; then
    record 1 "request-restart --wait postgres neo4j api web: ok, $(grep '^seconds=' <<<"$OUT") job-side, wall $((SECONDS - t0)) s"
    printf 'TIMING request-restart postgres neo4j api web: request->result %s s, job-side %s s\n' "$((SECONDS - t0))" \
      "$(sed -n 's/^seconds=//p' <<<"$OUT")" | tee -a "$log"
  else
    record 0 "request-restart --wait postgres neo4j api web" "($(tr '\n' ' ' <<<"$OUT"))"
  fi
  served="$("${VK[@]}" releases | sed -n 's/^current: *//p')"
  expect "health all ok after the four-service restart" \
    "api: ok .*release=$served neo4j=ok summaries=ok postgres=ok" "${VK[@]}" health
  if grep -q '^postgres: ok' <<<"$OUT" && grep -q '^neo4j: ok' <<<"$OUT" && grep -q '^api: ready' <<<"$OUT" &&
    grep -q '^web: ready (GET /readyz: 200; mcp tools 8' <<<"$OUT"; then
    record 1 "health after the four-service restart: postgres, neo4j, api ready, web ready (8 MCP tools)"
  else record 0 "health lines after the four-service restart"; fi
  expect "four-service restart: no ANTHROPIC_* / canary in the web instance" '^0$' web_env_scan
else
  printf 'SKIPPED in-job restart section (web not in VISIONKB_SERVICES)\n' | tee -a "$log"
fi

note "postgres stale lock (forced: SIGKILL as after a preemption) and fast failure"
if ! command -v apptainer >/dev/null 2>&1; then
  set +u
  # shellcheck disable=SC1090
  source "$(setting VISIONKB_MODULES_INIT)" && module load "$(setting VISIONKB_APPTAINER_MODULE)"
  set -u
fi
pg_inst="visionkb-$(setting VISIONKB_INSTANCE)-postgres"
pg_lock="$inst_dir/postgres/data/postmaster.pid"
pg_owner="$inst_dir/postgres/owner"
me_job="${SLURM_JOB_ID:-none}"
me_host="$(hostname -s)"
expect "postgres owner record: job $me_job on $me_host" "^job=$me_job\$" cat "$pg_owner"
pg_kill() { # SIGKILL the postgres instance (appinit + postmaster tree): what Slurm does KillWait after SIGTERM
  local p i
  p="$(apptainer instance list --json "$pg_inst" 2>/dev/null | sed -n 's/.*"pid": *\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  [[ -n "$p" ]] || return 1
  pkill -KILL -P "$p" || true
  kill -KILL "$p" || true
  for ((i = 0; i < 30; i++)); do
    apptainer instance list "$pg_inst" 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$pg_inst" || return 0
    sleep 1
  done
  return 1
}
check "SIGKILL the postgres instance" pg_kill
check "a stale postmaster.pid is left on the shared data dir" test -s "$pg_lock"
# 1. no owner record (a lock left by visionkb < 0.1.9): refuse at once, print the command
mv "$pg_owner" "$pg_owner.smoke-saved"
t0=$SECONDS
expect_fail "start postgres without an owner record: refused with the command to move the lock aside" \
  "no owner record.*|mkdir -p '.*/stale-locks' && mv '$pg_lock' " "${VK[@]}" start postgres
if grep -q "mv '$pg_lock' '$inst_dir/postgres/stale-locks/postmaster.pid.manual-" <<<"$OUT"; then
  record 1 "the printed command names the lock and a stale-locks/ target"
else record 0 "printed mv command"; fi
if ((SECONDS - t0 < 30)) && [[ -s "$pg_lock" ]]; then
  record 1 "refused in $((SECONDS - t0)) s (no wait for VISIONKB_START_TIMEOUT), lock untouched"
else record 0 "refused quickly, lock untouched" "($((SECONDS - t0)) s)"; fi
mv "$pg_owner.smoke-saved" "$pg_owner"
# 2. owner: this job's id on another host -> the job is RUNNING -> refuse
if [[ -n "${SLURM_JOB_ID:-}" ]]; then
  cp "$pg_owner" "$pg_owner.smoke-saved"
  sed -i "s/^host=.*/host=elsewhere/" "$pg_owner"
  expect_fail "start postgres while its owner job runs (job $SLURM_JOB_ID on another host): refused" \
    "started by job $SLURM_JOB_ID on elsewhere, which is RUNNING" "${VK[@]}" start postgres
  mv "$pg_owner.smoke-saved" "$pg_owner"
else
  printf 'SKIPPED owner-job-running case (not in a Slurm job)\n' | tee -a "$log"
fi
# 3. owner: a finished job (SMOKE_FINISHED_JOB) -> stale per sacct -> moved aside (then this run's own case below)
if [[ -n "${SMOKE_FINISHED_JOB:-}" ]]; then
  cp "$pg_owner" "$pg_owner.smoke-saved"
  sed -i -e "s/^job=.*/job=$SMOKE_FINISHED_JOB/" -e "s/^host=.*/host=elsewhere/" "$pg_owner"
  expect "start postgres, owner job $SMOKE_FINISHED_JOB finished: lock moved aside, postgres serves" \
    "moved stale lock $pg_lock aside to $inst_dir/postgres/stale-locks/postmaster.pid\..*its owner job $SMOKE_FINISHED_JOB \(on elsewhere\) is (COMPLETED|CANCELLED|FAILED|TIMEOUT|PREEMPTED)" \
    "${VK[@]}" start postgres
  rm -f "$pg_owner.smoke-saved"
  check "SIGKILL the postgres instance again" pg_kill
fi
# 4. owner = this job, instance gone (the real after-kill case) -> moved aside, postgres serves again
t0=$SECONDS
expect "start postgres after the kill: the stale lock (owner = this job, no instance) is moved aside" \
  "moved stale lock $pg_lock aside .*its owner is this job \($me_job on $me_host\) and no postgres instance runs here" \
  "${VK[@]}" start postgres
printf 'TIMING start postgres over a stale lock: %s s\n' "$((SECONDS - t0))" | tee -a "$log"
expect "moved lock kept (not deleted) in postgres/stale-locks/" 'postmaster\.pid\.' ls "$inst_dir/postgres/stale-locks"
served="$("${VK[@]}" releases | sed -n 's/^current: *//p')"
expect "health all ok after the stale-lock restart (API reconnects to postgres)" \
  "api: ok .*release=$served neo4j=ok summaries=ok postgres=ok" "${VK[@]}" health
# 5. fast failure: a throwaway instance whose postgres exits at once (data dir claims PG_VERSION 99) while
#    appinit stays up; VISIONKB_START_TIMEOUT=1800 must not be waited for; no lock, so the owner record is retired
ff=(env VISIONKB_PG_PORT="${SMOKE_FF_PG_PORT:-$(($(setting VISIONKB_PG_PORT) + 7))}" VISIONKB_START_TIMEOUT=1800
  "$repo/bin/visionkb" --env-file "$env_file" --instance "$(setting VISIONKB_INSTANCE)-ff")
ff_dir="$("${ff[@]}" config | sed -n 's/^instance_dir=//p')"
if [[ -n "$ff_dir" && ! -e "$ff_dir" ]]; then
  check "init throwaway instance $(basename "$ff_dir")" "${ff[@]}" init
  echo 99 >"$ff_dir/postgres/data/PG_VERSION"
  : >"$ff_dir/postgres/data/postgresql.conf" # so postgres gets as far as the version check (FATAL)
  t0=$SECONDS
  expect_fail "start postgres whose server exits at start-up: fails fast with the FATAL line" \
    "postgres server process exited during start-up.*|FATAL: .*(incompatible|version 99)" "${ff[@]}" start postgres
  ff_s=$((SECONDS - t0))
  if grep -qE 'FATAL: .*(incompatible|version 99)' <<<"$OUT"; then record 1 "the FATAL line of this start is shown"
  else record 0 "FATAL line shown"; fi
  if ((ff_s < 60)); then record 1 "fast failure in $ff_s s (VISIONKB_START_TIMEOUT=1800)"
  else record 0 "fast failure" "($ff_s s)"; fi
  printf 'TIMING fast failure of a postgres that exits at start-up: %s s (timeout 1800 s)\n' "$ff_s" | tee -a "$log"
  expect "the empty instance was stopped" 'postgres +stopped' "${ff[@]}" status
  if [[ ! -e "$ff_dir/postgres/owner" && -s "$ff_dir/postgres/owner.last" ]]; then
    record 1 "fast failure without a lock: owner record retired (owner.last)"
  else record 0 "owner record retired after the fast failure"; fi
  chmod -R u+w "$ff_dir" 2>/dev/null || true
  rm -rf "$ff_dir"
else
  record 0 "throwaway instance dir $ff_dir already exists"
fi

note "restore"
# same edge, different run_id (the API de-duplicates on run_id + edge)
check "second proposal" curl -fsS -o /dev/null -H "@$H_CUR" -H 'Content-Type: application/json' \
  -d "${body/smoke-test/smoke-test-2}" "$api/proposals"
expect "proposals before restore: 2" '"total": ?2' curl -fsS -H "@$H_CUR" "$api/proposals"
check "restore backup" "${VK[@]}" restore "$backup_dir" --yes
expect "proposals after restore: 1" '"total": ?1' curl -fsS -H "@$H_CUR" "$api/proposals"

note "stop"
capture "${VK[@]}" stop
order="$(grep -oE 'stop (postgres|neo4j|api|web): stopped' <<<"$OUT" | awk '{print $2}' | tr -d ':' | xargs)"
want="$(xargs <<<"$(for s in web api neo4j postgres; do [[ " $services " == *" $s "* ]] && echo "$s"; done)")"
if [[ $RC -eq 0 && "$order" == "$want" ]]; then record 1 "stop: $order (reverse of the start order)"; else
  record 0 "stop" "(order: $order, wanted: $want, rc $RC)"
fi
expect "all stopped" 'postgres +stopped' "${VK[@]}" status
trap - EXIT
rm -f "$H_READ" "$H_CUR"

printf '\nRESULT: %d passed, %d failed\n' "$pass" "$fail" | tee -a "$log"
((fail == 0))
