#!/usr/bin/env bats
# bin/visionkb without real containers: the verified store cache (dump records, ensure-loaded decisions) and the
# in-job restart control (request-restart validation, process-requests, the sbatch watcher loop).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  VK="$REPO/bin/visionkb"
  TMP="$(mktemp -d)"
  TMP="$(cd "$TMP" && pwd)"
  # live stores must be on a local filesystem (the network-FS guard); bats' TMPDIR may be on one
  LSTORE="$(mktemp -d /tmp/vkb-bats-store.XXXXXX)"
  unset VISIONKB_ENV_FILE VISIONKB_DATA_ROOT VISIONKB_WORK_DIR VISIONKB_INSTANCE VISIONKB_KG_RELEASE \
    VISIONKB_DEPLOY_DIR VISIONKB_RELEASES_DIR VISIONKB_BUNDLES_DIR VISIONKB_SERVICES VISIONKB_API_PORT \
    VISIONKB_KG_BUNDLE_SHA256 VISIONKB_MCP_IMAGE VISIONKB_SKILLS_RELEASE VISIONKB_IMAGES_DIR VISIONKB_WEB_IMAGE \
    VISIONKB_WEB_PORT VISIONKB_ID_CHECK VISIONKB_STORE_DUMPS VISIONKB_NEO4J_IMAGE VISIONKB_POSTGRES_IMAGE \
    VISIONKB_API_IMAGE VISIONKB_STORE_DIR SLURM_JOB_ID VISIONKB_CONTROL_POLL VISIONKB_REQUEST_MAX_AGE
  cat >"$TMP/test.env" <<EOF
VISIONKB_WORK_DIR=$TMP/work
VISIONKB_RELEASES_DIR=$TMP/releases
VISIONKB_STORE_DIR=$LSTORE
VISIONKB_API_PORT=39870
VISIONKB_PG_PORT=39872
VISIONKB_NEO4J_LOAD_BOLT_PORT=39871
VISIONKB_SERVICES=postgres neo4j api web
VISIONKB_WEB_PORT=39873
EOF
  INST="$TMP/work/visionkb-deploy/default"
  IMG="$TMP/work/visionkb-deploy/images"
  mkdir -p "$TMP/fakebin" "$TMP/fakestate"
  export FAKE_APPTAINER_LOG="$TMP/apptainer.log" FAKE_STATE="$TMP/fakestate"
  printf '#!/usr/bin/env bash\nFAKE_APPTAINER_LOG=%q\nFAKE_STATE=%q\n' "$FAKE_APPTAINER_LOG" "$FAKE_STATE" >"$TMP/fakebin/apptainer"
  cat >>"$TMP/fakebin/apptainer" <<'EOF'
printf '%s\n' "$*" >>"$FAKE_APPTAINER_LOG"
case "$1" in
instance)
  case "$2" in
  list)
    echo "INSTANCE NAME    PID    IP    IMAGE"
    if [[ -e "$FAKE_STATE/$3" ]]; then echo "$3    4242          /x.sif"; fi
    ;;
  run) : >"$FAKE_STATE/${*: -1}" ;;
  stop) rm -f "$FAKE_STATE/${*: -1}" ;;
  esac
  ;;
exec)
  for a in "$@"; do case "$a" in instance://*) inst="${a#instance://}" ;; esac; done
  if [[ " $* " == *" pg_ctl "* && -n "${inst:-}" ]]; then rm -f "$FAKE_STATE/$inst"; fi
  ;;
esac
exit 0
EOF
  chmod +x "$TMP/fakebin/apptainer"
  export PATH="$TMP/fakebin:$PATH"
  "$VK" --env-file "$TMP/test.env" init >/dev/null 2>&1
}

teardown() {
  chmod -R u+w "$TMP" "$LSTORE" 2>/dev/null || true
  rm -rf "$TMP" "$LSTORE"
}

vk() { "$VK" --env-file "$TMP/test.env" "$@"; }
cfg() { vk config | sed -n "s/^$1=//p"; }
fake_sif() { # fake_sif REF: an "already pulled" SIF + .ref in the images dir; prints its path
  local p
  p="$IMG/$(bash -c 'source "$1/libexec/visionkb-env.sh"; read -r n t d <<<"$(image_parts "$2")"; s="_${d#sha256:}"; printf "%s_%s%s.sif" "${n##*/}" "${t/#-/latest}" "${s:0:13}"' _ "$REPO" "$1")"
  mkdir -p "$IMG"
  : >"$p"
  printf '%s\n' "$1" >"$p.ref"
  printf '%s' "$p"
}
# a recorded, id-checked load of fixture R1 (store not on this node) and a dump record for it
R1=visionkb-0000.01.1
record_r1() {
  python3 "$REPO/tests/fixtures/make_fixture_release.py" "$TMP/releases" "$R1" >/dev/null
  local m rec="$INST/neo4j/loaded/$R1"
  m="$(sha256sum "$TMP/releases/$R1/manifest.json" | cut -d' ' -f1)"
  mkdir -p "$rec"
  printf '{"kg_release":"%s","loaded_utc":"2026-11-11T00:00:00Z","nodes":11,"relationships":10,"indexes":9,"neo4j_version":"2026.10.1","manifest_sha256":"%s","id_check":"ok","node_ids_sha256":"aa","rel_keys_sha256":"bb"}\n' "$R1" "$m" >"$rec/LOADED.json"
  printf '%s\n' "$TMP/releases/$R1" >"$rec/SOURCE"
  printf '%s\n' "$LSTORE/neo4j/releases/$R1" >"$rec/STORE"
  printf '%s\n' "$R1" >"$INST/state/current"
  fake_sif "$(cfg VISIONKB_NEO4J_IMAGE)" >/dev/null
}
dump_r1() { # dump_r1 [manifest_sha] [image_digest] [id_check]
  local d="$INST/neo4j/dumps/$R1" m dig sha
  m="${1:-$(sha256sum "$TMP/releases/$R1/manifest.json" | cut -d' ' -f1)}"
  dig="${2:-$(cfg VISIONKB_NEO4J_IMAGE | sed 's/.*@//')}"
  mkdir -p "$d"
  head -c 4096 /dev/urandom >"$d/$R1.dump"
  sha="$(sha256sum "$d/$R1.dump" | cut -d' ' -f1)"
  printf '%s  %s.dump\n' "$sha" "$R1" >"$d/$R1.dump.sha256"
  printf '{"kg_release":"%s","manifest_sha256":"%s","neo4j_version":"2026.10.1","neo4j_image":"x","neo4j_image_digest":"%s","nodes":11,"relationships":10,"indexes":9,"id_check":"%s","node_ids_sha256":"aa","rel_keys_sha256":"bb","loaded_utc":"2026-11-11T00:00:00Z","dump_file":"%s.dump","dump_sha256":"%s","dump_bytes":4096,"created_utc":"2026-11-11T00:01:00Z","deploy_version":"0.1.7"}\n' \
    "$R1" "$m" "$dig" "${3:-ok}" "$R1" "$sha" >"$d/DUMP.json"
}

@test "dump record: matches; stale on manifest, neo4j image, unchecked load; none when absent" {
  record_r1
  run vk releases
  [[ "$output" == *"dump: none"* ]]
  dump_r1
  run vk releases
  [[ "$output" == *"dump: matches (4096 bytes, created 2026-11-11T00:01:00Z"* ]]
  dump_r1 "$(printf 'c%.0s' {1..64})"
  run vk releases
  [[ "$output" == *"dump: stale: manifest differs from the load record"* ]]
  dump_r1 "" "sha256:$(printf 'd%.0s' {1..64})"
  run vk releases
  [[ "$output" == *"dump: stale: neo4j image differs"* ]]
  dump_r1 "" "" skipped
  run vk releases
  [[ "$output" == *"dump: stale: the dumped load was not id-checked"* ]]
  dump_r1
  echo tamper >>"$TMP/releases/$R1/manifest.json"
  run vk releases
  [[ "$output" == *"dump: stale: the release source's manifest.json changed"* ]]
}

@test "ensure-loaded: a matching dump is restored first; a failed restore falls back to the full load" {
  record_r1
  dump_r1
  run vk ensure-loaded
  [ "$status" -eq 1 ] # the fake container writes no store
  [[ "$output" == *"verifying the dump sha256"*"restoring from the dump into $LSTORE/neo4j/releases/$R1"* ]]
  [[ "$output" == *"restore from the dump failed"*"removed the dump of $R1 (replaced by this load)"* ]]
  env="$INST/run/restore.env"
  grep -qx "VISIONKB_LOAD_MODE='restore'" "$env"
  grep -qx "VISIONKB_EXPECT_NODES='11'" "$env"
  grep -qx "VISIONKB_EXPECT_RELS='10'" "$env"
  grep -q "^VISIONKB_DUMP_SHA256='[0-9a-f]\{64\}'$" "$env"
  grep -q -- "-B $INST/neo4j/dumps/$R1:/dump:ro" "$FAKE_APPTAINER_LOG"
}

@test "ensure-loaded: dump sha256 mismatch or VISIONKB_ID_CHECK=always -> full load, no restore" {
  record_r1
  dump_r1
  printf '%064d  %s.dump\n' 0 "$R1" >"$INST/neo4j/dumps/$R1/$R1.dump.sha256"
  run vk ensure-loaded
  [ "$status" -eq 1 ]
  [[ "$output" == *"dump sha256 mismatch"*"full load"* ]]
  [[ "$output" != *"restoring from the dump"* ]]
  [ ! -e "$INST/run/restore.env" ]
  dump_r1
  VISIONKB_ID_CHECK=always run vk ensure-loaded
  [ "$status" -eq 1 ]
  [[ "$output" == *"VISIONKB_ID_CHECK=always: full load with the id check"* ]]
  [[ "$output" != *"restoring from the dump"* ]]
  [ ! -e "$INST/run/restore.env" ]
  VISIONKB_ID_CHECK=sometimes run vk config
  [ "$status" -eq 1 ]
  [[ "$output" == *"VISIONKB_ID_CHECK must be first or always"* ]]
  run vk config
  [[ "$output" == *$'\nVISIONKB_ID_CHECK=first\n'* && "$output" == *$'\nVISIONKB_STORE_DUMPS=1\n'* ]]
  [[ "$output" == *"dumps_dir=$INST/neo4j/dumps"* && "$output" == *"control_dir=$INST/control"* ]]
}

@test "load-release --force never reuses a dump: the old dump is removed before the full load" {
  record_r1
  dump_r1
  run vk load-release "$R1" --force
  [ "$status" -eq 1 ] # fake container
  [[ "$output" == *"removed the dump of $R1 (replaced by this load)"* ]]
  [[ "$output" != *"restoring from the dump"* ]]
  [ ! -e "$INST/neo4j/dumps/$R1" ]
}

@test "init creates the control dir and dumps dir with mode 700" {
  for d in control control/requests control/processing control/results neo4j/dumps; do
    [ "$(stat -c %a "$INST/$d")" = 700 ]
  done
}

@test "request-restart: validates services and images; writes the request atomically as data (mode 600)" {
  run vk request-restart nginx
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown service 'nginx'"* ]]
  VISIONKB_SERVICES="postgres neo4j api" run vk request-restart web
  [ "$status" -eq 1 ]
  [[ "$output" == *"web is not in VISIONKB_SERVICES"* ]]
  run vk request-restart web
  [ "$status" -eq 1 ]
  [[ "$output" == *"SIF"*"missing (run 'visionkb pull web'"* ]]
  VISIONKB_WEB_IMAGE=ghcr.io/lijinbio/visionkb-web:latest run vk request-restart web
  [ "$status" -eq 1 ]
  [[ "$output" == *"not digest-pinned"* ]]
  sif="$(fake_sif "$(cfg VISIONKB_WEB_IMAGE)")"
  run vk request-restart web web
  [ "$status" -eq 0 ]
  id="$(tail -n 1 <<<"$output")"
  [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9-]+-[0-9]+-[0-9]+$ ]]
  f="$INST/control/requests/$id.req"
  [ "$(stat -c %a "$f")" = 600 ]
  grep -qx "services=web" "$f" # de-duplicated
  grep -qx "image_web=$(cfg VISIONKB_WEB_IMAGE)" "$f"
  grep -qx "sif_web=$sif" "$f"
  grep -qx "deploy_version=$("$VK" --version | awk '{print $2}')" "$f"
  [ -z "$(find "$INST/control/requests" -name '.*.tmp')" ]
  [[ "$output" == *"no job has watched"* ]]
}

@test "process-requests: refuses outside a job and where no instance runs" {
  run vk process-requests
  [ "$status" -eq 1 ]
  [[ "$output" == *"runs in the job that serves the instance"* ]]
  run vk process-requests --local
  [ "$status" -eq 1 ]
  [[ "$output" == *"no instance of 'default' runs on this node"* ]]
}

write_req() { # write_req ID LINES...: a hand-made request file
  local id="$1"
  shift
  (umask 077 && printf '%s\n' "id=$id" "created_epoch=$(date +%s)" "deploy_version=0" "requested_by=t@t" "$@" \
    >"$INST/control/requests/$id.req")
}

@test "process-requests: rejects bad requests without running anything (and never executes values)" {
  : >"$FAKE_STATE/visionkb-default-postgres"
  pg="$(cfg VISIONKB_POSTGRES_IMAGE)"
  pgsif="$(fake_sif "$pg")"
  other="$(fake_sif "docker.io/library/postgres:17.11@sha256:$(printf 'e%.0s' {1..64})")"
  : >"$IMG/wrong.sif"
  echo "$pg" >"$IMG/wrong.sif.ref"
  write_req r-tag "services=postgres" "image_postgres=postgres:17.11" "sif_postgres=$pgsif"
  write_req r-repo "services=postgres" "image_postgres=docker.io/library/postgres:17.11@sha256:$(printf 'e%.0s' {1..64})" "sif_postgres=$other"
  write_req r-path "services=postgres" "image_postgres=$pg" "sif_postgres=$IMG/wrong.sif"
  write_req r-out "services=postgres" "image_postgres=$pg" "sif_postgres=/tmp/x.sif"
  echo "other" >"$pgsif.ref.bak"
  write_req r-inject "services=postgres" "image_postgres=\$(touch $TMP/pwned)" "sif_postgres=$pgsif"
  write_req r-key "services=postgres" "command=rm -rf /" "image_postgres=$pg" "sif_postgres=$pgsif"
  write_req r-svc "services=postgres nginx" "image_postgres=$pg" "sif_postgres=$pgsif"
  (umask 077 && printf '%s\n' "id=r-old" "created_epoch=1" "services=postgres" "image_postgres=$pg" "sif_postgres=$pgsif" \
    >"$INST/control/requests/r-old.req")
  : >"$FAKE_APPTAINER_LOG"
  run vk process-requests --local
  [ "$status" -eq 0 ]
  r="$INST/control/results"
  grep -qx 'status=error' "$r/r-tag.result" && grep -q 'not digest-pinned' "$r/r-tag.result"
  grep -q 'is not the postgres repository' "$r/r-repo.result"
  grep -q 'is not the images dir path' "$r/r-path.result"
  grep -q 'is not the images dir path' "$r/r-out.result"
  grep -q 'not KEY=VALUE of allowed characters' "$r/r-inject.result"
  grep -q 'unknown key command' "$r/r-key.result"
  grep -q 'unknown service nginx' "$r/r-svc.result"
  grep -q 'expired' "$r/r-old.result"
  [ ! -e "$TMP/pwned" ]
  ! grep -qE '^instance (run|stop)' "$FAKE_APPTAINER_LOG"
  [ -z "$(ls -A "$INST/control/requests")" ] && [ -z "$(ls -A "$INST/control/processing")" ]
  [ "$(stat -c %a "$r/r-tag.result")" = 600 ]
  grep -q '^job=local node=' "$INST/control/watcher"
}

@test "request-restart --wait: the job restarts the service and the result is printed" {
  : >"$FAKE_STATE/visionkb-default-postgres"
  fake_sif "$(cfg VISIONKB_POSTGRES_IMAGE)" >/dev/null
  (sleep 3 && "$VK" --env-file "$TMP/test.env" process-requests --local >/dev/null 2>&1) &
  run vk request-restart --wait --timeout 60 postgres
  wait
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nstatus=ok\n'* && "$output" == *$'\nmessage=restarted\n'* ]]
  [[ "$output" == *"image_postgres=$(cfg VISIONKB_POSTGRES_IMAGE)"* ]]
  [[ "$output" == *$'\nseconds='* && "$output" == *$'\nnode='* ]]
  grep -q 'pg_ctl' "$FAKE_APPTAINER_LOG"
  grep -q '^instance run .* visionkb-default-postgres postgres -c ' "$FAKE_APPTAINER_LOG"
}

@test "web image upgrade: the job starts web from the requested digest's SIF (not the configured one)" {
  : >"$FAKE_STATE/visionkb-default-web"
  new="ghcr.io/lijinbio/visionkb-web:9.9.9@sha256:$(printf 'f%.0s' {1..64})"
  newsif="$(fake_sif "$new")"
  VISIONKB_WEB_IMAGE="$new" run vk request-restart web
  [ "$status" -eq 0 ]
  : >"$FAKE_APPTAINER_LOG"
  VISIONKB_WEB_START_TIMEOUT=1 run vk process-requests --local
  [ "$status" -eq 0 ]
  res="$(ls "$INST"/control/results/*.result)"
  grep -qx "image_web=$new" "$res"
  grep -q "^instance run .* $newsif visionkb-default-web$" "$FAKE_APPTAINER_LOG"
  # the fake instance never answers /healthz: error, then a recovery attempt with the configured image
  grep -qx 'status=error' "$res"
  grep -q '^recovered_web=' "$res"
}

@test "sbatch job: polls the control dir (process-requests) and health-checks on its interval" {
  mkdir -p "$TMP/stub/bin"
  cat >"$TMP/stub/bin/visionkb" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/stub.log"
case "\$1" in tunnel-hint) echo "ssh -N -L 1:127.0.0.1:1" ;; esac
exit 0
EOF
  chmod +x "$TMP/stub/bin/visionkb"
  VISIONKB_DEPLOY_REPO="$TMP/stub" VISIONKB_HEALTH_INTERVAL=4 VISIONKB_CONTROL_POLL=1 \
    bash "$REPO/slurm/visionkb.sbatch" >"$TMP/job.out" 2>&1 &
  pid=$!
  sleep 7
  kill -TERM "$pid"
  wait "$pid" || true
  head -n 3 "$TMP/stub.log" | tr '\n' ' ' | grep -q '^config ensure-loaded start '
  [ "$(grep -c '^process-requests$' "$TMP/stub.log")" -ge 4 ]
  [ "$(grep -c '^health$' "$TMP/stub.log")" -ge 2 ] # after start, then every 4 s
  [ "$(tail -n 1 "$TMP/stub.log")" = stop ]
  grep -q 'stopping' "$TMP/job.out"
}
