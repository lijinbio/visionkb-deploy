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
VISIONKB_NEO4J_BOLT_PORT=39874
VISIONKB_NEO4J_HTTP_PORT=0
EOF
  INST="$TMP/work/visionkb-deploy/default"
  IMG="$TMP/work/visionkb-deploy/images"
  mkdir -p "$TMP/fakebin" "$TMP/fakestate"
  export FAKE_APPTAINER_LOG="$TMP/apptainer.log" FAKE_STATE="$TMP/fakestate" APPTAINER_CONFIGDIR="$TMP/aconf"
  printf '#!/usr/bin/env bash\nFAKE_APPTAINER_LOG=%q\nFAKE_STATE=%q\n' "$FAKE_APPTAINER_LOG" "$FAKE_STATE" >"$TMP/fakebin/apptainer"
  cat >>"$TMP/fakebin/apptainer" <<'EOF'
printf '%s\n' "$*" >>"$FAKE_APPTAINER_LOG"
# instance NAME -> service (visionkb-<instance>-<svc>)
svc_of() { printf '%s' "${1##*-}"; }
errlog() { printf '%s/instances/logs/%s/%s/%s.err' "${APPTAINER_CONFIGDIR:-$HOME/.apptainer}" "$(hostname)" "$(id -un)" "$1"; }
kill_init() { # stop the fake init process (and its server child) of instance $1
  local p
  if [[ -s "$FAKE_STATE/$1.init" ]]; then
    p="$(cat "$FAKE_STATE/$1.init")"
    pkill -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
    rm -f "$FAKE_STATE/$1.init"
  fi
}
case "$1" in
instance)
  case "$2" in
  list)
    json=0
    [[ "$3" == --json ]] && { json=1; shift; }
    if ((json)); then
      if [[ -e "$FAKE_STATE/$3" ]]; then
        printf '{"instances":[{"instance":"%s","pid":%s,"img":"/x.sif","ip":"","logErrPath":"%s","logOutPath":"%s"}]}\n' \
          "$3" "$(cat "$FAKE_STATE/$3.init" 2>/dev/null || echo 0)" "$(errlog "$3")" "$(errlog "$3" | sed 's/err$/out/')"
      else
        echo '{"instances":[]}'
      fi
    else
      echo "INSTANCE NAME    PID    IP    IMAGE"
      if [[ -e "$FAKE_STATE/$3" ]]; then echo "$3    4242          /x.sif"; fi
    fi
    ;;
  run)
    name="" envf="" prev="" pgdata=""
    for a in "$@"; do
      [[ "$prev" == --env-file ]] && envf="$a"
      [[ "$prev" == -B && "$a" == *:/var/lib/postgresql/data ]] && pgdata="${a%%:*}"
      case "$a" in visionkb-*-*) name="$a" ;; esac
      prev="$a"
    done
    kill_init "$name" # one instance per name
    : >"$FAKE_STATE/$name"
    log="$(errlog "$name")"
    mkdir -p "$(dirname "$log")"
    svc="$(svc_of "$name")"
    # the instance's init process; its child is the "server" unless $FAKE_STATE/server-exits-<svc> exists, or the
    # postgres data dir holds a postmaster.pid (like postgres refusing a lock it considers live)
    if [[ -e "$FAKE_STATE/server-exits-$svc" ]] || [[ -n "$pgdata" && -e "$pgdata/postmaster.pid" ]]; then
      echo "$(date) [15] FATAL:  lock file \"postmaster.pid\" already exists" >>"$log"
      echo "$(date) [15] HINT:  Is another postmaster (PID 15) running in data directory \"/var/lib/postgresql/data\"?" >>"$log"
      : >"$FAKE_STATE/$name.dead"
      nohup sleep 100000 >/dev/null 2>&1 </dev/null 3>&- &
    else
      echo "$(date) server started" >>"$log"
      rm -f "$FAKE_STATE/$name.dead"
      [[ -z "$pgdata" ]] || printf '14\n/var/lib/postgresql/data\n' >"$pgdata/postmaster.pid"
      nohup bash -c 'sleep 100000 & wait' >/dev/null 2>&1 </dev/null 3>&- &
    fi
    echo $! >"$FAKE_STATE/$name.init"
    [[ -z "$pgdata" ]] || printf '%s\n' "$pgdata" >"$FAKE_STATE/$name.pgdata"
    # api / web: a local HTTP stub on the instance's port answers /v1/health, /v1/ready, /healthz, /readyz with 200
    # (not when $FAKE_STATE/no-http exists: a file, because the web instance is started with env -i)
    port=""
    case "$name" in
    *-api) port="$(sed -n "s/^VISIONKB_API_PORT='\(.*\)'$/\1/p" "$envf")" ;;
    *-web) port="$(sed -n "s/^VISIONKB_WEB_PORT='\(.*\)'$/\1/p" "$envf")" ;;
    esac
    if [[ -n "$port" && ! -e "$FAKE_STATE/no-http" && ! -e "$FAKE_STATE/$name.dead" ]]; then
      mkdir -p "$FAKE_STATE/www/v1"
      for f in v1/health v1/ready healthz readyz; do echo '{"status":"ok","n_tools":8}' >"$FAKE_STATE/www/$f"; done
      nohup python3 -m http.server "$port" --bind 127.0.0.1 --directory "$FAKE_STATE/www" >/dev/null 2>&1 </dev/null 3>&- &
      echo $! >"$FAKE_STATE/$name.pid"
      for _ in $(seq 50); do (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break; sleep 0.1; done
    fi
    ;;
  stop)
    name="${*: -1}"
    rm -f "$FAKE_STATE/$name" "$FAKE_STATE/$name.dead"
    kill_init "$name"
    if [[ -s "$FAKE_STATE/$name.pid" ]]; then kill "$(cat "$FAKE_STATE/$name.pid")" 2>/dev/null; rm -f "$FAKE_STATE/$name.pid"; sleep 0.3; fi
    ;;
  esac
  ;;
exec)
  for a in "$@"; do case "$a" in instance://*) inst="${a#instance://}" ;; esac; done
  if [[ -n "${inst:-}" && -e "$FAKE_STATE/$inst.dead" ]]; then exit 1; fi # no server: pg_isready / cypher fail
  if [[ " $* " == *" pg_ctl "* && -n "${inst:-}" ]]; then
    # a clean stop: the server exits and removes its lock; the instance ends (real appinit would stay: stop follows)
    if [[ -s "$FAKE_STATE/$inst.pgdata" ]]; then rm -f "$(cat "$FAKE_STATE/$inst.pgdata")/postmaster.pid"; fi
    rm -f "$FAKE_STATE/$inst"
    kill_init "$inst"
  fi
  ;;
esac
exit 0
EOF
  # fake squeue / sacct: the state of job ID is the content of $FAKE_STATE/squeue-ID / sacct-ID (none: unknown)
  printf '#!/usr/bin/env bash\nFAKE_STATE=%q\n' "$FAKE_STATE" >"$TMP/fakebin/squeue"
  cat >>"$TMP/fakebin/squeue" <<'EOF'
while (($#)); do [[ "$1" == -j ]] && id="$2"; shift; done
if [[ -s "$FAKE_STATE/squeue-$id" ]]; then cat "$FAKE_STATE/squeue-$id"; else echo "slurm_load_jobs error: Invalid job id specified" >&2; exit 1; fi
EOF
  printf '#!/usr/bin/env bash\nFAKE_STATE=%q\n' "$FAKE_STATE" >"$TMP/fakebin/sacct"
  cat >>"$TMP/fakebin/sacct" <<'EOF'
while (($#)); do [[ "$1" == -j ]] && id="$2"; shift; done
[[ -s "$FAKE_STATE/sacct-$id" ]] && cat "$FAKE_STATE/sacct-$id"
exit 0
EOF
  chmod +x "$TMP/fakebin/squeue" "$TMP/fakebin/sacct"
chmod +x "$TMP/fakebin/apptainer"
  export PATH="$TMP/fakebin:$PATH"
  "$VK" --env-file "$TMP/test.env" init >/dev/null 2>&1
}

teardown() {
  local f
  for f in "$TMP"/fakestate/*.pid "$TMP"/fakestate/*.init; do
    [[ -s "$f" ]] || continue
    pkill -P "$(cat "$f")" 2>/dev/null || true
    kill "$(cat "$f")" 2>/dev/null || true
  done
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

@test "web image upgrade: the job starts web from the requested digest's SIF; a failed start is recovered" {
  : >"$FAKE_STATE/visionkb-default-web"
  new="ghcr.io/lijinbio/visionkb-web:9.9.9@sha256:$(printf 'f%.0s' {1..64})"
  newsif="$(fake_sif "$new")"
  # 1. the new image never answers (no HTTP stub): error, then a recovery attempt with the configured image
  : >"$FAKE_STATE/no-http"
  VISIONKB_WEB_IMAGE="$new" run vk request-restart web
  [ "$status" -eq 0 ]
  id1="$(tail -n 1 <<<"$output")"
  : >"$FAKE_APPTAINER_LOG"
  VISIONKB_WEB_START_TIMEOUT=1 run vk process-requests --local
  [ "$status" -eq 0 ]
  res="$INST/control/results/$id1.result"
  grep -qx "image_web=$new" "$res"
  grep -q "^instance run .* $newsif visionkb-default-web$" "$FAKE_APPTAINER_LOG"
  grep -qx 'status=error' "$res"
  grep -q '^recovered_web=' "$res"
  # 2. the new image answers: ok, web started from the requested SIF
  rm -f "$FAKE_STATE/no-http" "$FAKE_STATE/visionkb-default-web"
  : >"$FAKE_STATE/visionkb-default-web"
  VISIONKB_WEB_IMAGE="$new" run vk request-restart web
  id2="$(tail -n 1 <<<"$output")"
  : >"$FAKE_APPTAINER_LOG"
  run vk process-requests --local
  [ "$status" -eq 0 ]
  res="$INST/control/results/$id2.result"
  grep -qx 'status=ok' "$res" && grep -qx "image_web=$new" "$res" && grep -qx 'web_readyz=200' "$res"
  grep -q "^instance run .* $newsif visionkb-default-web$" "$FAKE_APPTAINER_LOG"
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

# R1 recorded, current, and its store present on this node (what start_neo4j / start_api need)
loaded_r1() {
  record_r1
  local st="$LSTORE/neo4j/releases/$R1"
  mkdir -p "$st/data"
  cp "$INST/neo4j/loaded/$R1/LOADED.json" "$st/LOADED.json"
  local s
  for s in postgres neo4j api web; do fake_sif "$(cfg "VISIONKB_$(tr a-z A-Z <<<"$s")_IMAGE")" >/dev/null; done
}

@test "request keys with digits (image_neo4j, sif_neo4j) are accepted: a neo4j restart request is processed" {
  loaded_r1
  : >"$FAKE_STATE/visionkb-default-neo4j"
  run vk request-restart neo4j
  [ "$status" -eq 0 ]
  id="$(tail -n 1 <<<"$output")"
  grep -qx "image_neo4j=$(cfg VISIONKB_NEO4J_IMAGE)" "$INST/control/requests/$id.req"
  : >"$FAKE_APPTAINER_LOG"
  run vk process-requests --local
  [ "$status" -eq 0 ]
  res="$INST/control/results/$id.result"
  grep -qx 'status=ok' "$res"
  grep -qx 'message=restarted' "$res"
  grep -qx 'services=neo4j' "$res"
  grep -qx "image_neo4j=$(cfg VISIONKB_NEO4J_IMAGE)" "$res"
  grep -q '^instance stop .*visionkb-default-neo4j$' "$FAKE_APPTAINER_LOG"
  grep -q '^instance run .*visionkb-default-neo4j$' "$FAKE_APPTAINER_LOG"
}

@test "a request for all four services is processed: stop web api neo4j postgres, start postgres neo4j api web" {
  loaded_r1
  # all four running (api and web as HTTP stubs, as the fake starts them)
  for s in postgres neo4j; do : >"$FAKE_STATE/visionkb-default-$s"; done
  run vk start api web
  [ "$status" -eq 0 ]
  run vk request-restart postgres neo4j api web
  [ "$status" -eq 0 ]
  id="$(tail -n 1 <<<"$output")"
  : >"$FAKE_APPTAINER_LOG"
  run vk process-requests --local
  [ "$status" -eq 0 ]
  res="$INST/control/results/$id.result"
  grep -qx 'status=ok' "$res"
  grep -qx 'services=postgres neo4j api web' "$res"
  for s in postgres neo4j api web; do grep -qx "image_$s=$(cfg "VISIONKB_$(tr a-z A-Z <<<"$s")_IMAGE")" "$res"; done
  grep -qx 'web_readyz=200' "$res" && grep -qx 'api_ready=200' "$res"
  # order: stops web, api, neo4j (postgres via pg_ctl), then starts postgres, neo4j, api, web
  order="$(grep -oE '^(instance (stop|run) .*visionkb-default-(postgres|neo4j|api|web)( |$)|exec .*instance://visionkb-default-postgres pg_ctl)' "$FAKE_APPTAINER_LOG" |
    sed -E 's/^instance (stop|run) .*visionkb-default-([a-z0-9]+).*/\1 \2/; s/^exec .*pg_ctl.*/stop postgres/' | xargs)"
  [ "$order" = "stop web stop api stop neo4j stop postgres run postgres run neo4j run api run web" ]
}

@test "the key pattern still rejects unknown keys (command=, image_neo4jx=) and keys not starting with a letter" {
  : >"$FAKE_STATE/visionkb-default-postgres"
  nj="$(cfg VISIONKB_NEO4J_IMAGE)"
  write_req k-cmd "services=neo4j" "command=rm -rf /" "image_neo4j=$nj" "sif_neo4j=/x"
  write_req k-unk "services=neo4j" "image_neo4jx=$nj" "sif_neo4j=/x"
  write_req k-digit "services=neo4j" "4image=$nj"
  write_req k-upper "services=neo4j" "Image_neo4j=$nj"
  : >"$FAKE_APPTAINER_LOG"
  run vk process-requests --local
  [ "$status" -eq 0 ]
  r="$INST/control/results"
  grep -q 'unknown key command' "$r/k-cmd.result"
  grep -q 'unknown key image_neo4jx' "$r/k-unk.result"
  grep -q 'not KEY=VALUE of allowed characters' "$r/k-digit.result"
  grep -q 'not KEY=VALUE of allowed characters' "$r/k-upper.result"
  for f in k-cmd k-unk k-digit k-upper; do grep -qx 'status=error' "$r/$f.result"; done
  ! grep -qE '^instance (run|stop)' "$FAKE_APPTAINER_LOG"
}


# --- postgres lock owner, stale locks, fast failure (0.1.9) ---------------------------------------------------
pg_sif() { fake_sif "$(cfg VISIONKB_POSTGRES_IMAGE)" >/dev/null; }
PGN=visionkb-default-postgres
stale_lock() { # stale_lock JOB HOST: what a killed postmaster leaves, plus an owner record (JOB empty: none)
  printf '15\n/var/lib/postgresql/data\n' >"$INST/postgres/data/postmaster.pid"
  : >"$INST/postgres/run/.s.PGSQL.39872.lock"
  rm -f "$INST/postgres/owner"
  if [[ -n "$1" ]]; then printf 'job=%s\nhost=%s\nstarted_utc=2026-11-11T19:40:00Z\n' "$1" "$2" >"$INST/postgres/owner"; fi
}

@test "postgres start records the owner (Slurm job, host); status shows it; a clean stop retires it" {
  pg_sif
  SLURM_JOB_ID=111 run vk start postgres
  [ "$status" -eq 0 ]
  grep -qx 'job=111' "$INST/postgres/owner"
  grep -qx "host=$(hostname -s)" "$INST/postgres/owner"
  [ -e "$INST/postgres/data/postmaster.pid" ]
  run vk status
  [[ "$output" == *"postgres owner: job 111 on $(hostname -s) since "*"(postmaster.pid present)"* ]]
  SLURM_JOB_ID=111 run vk stop postgres
  [ "$status" -eq 0 ]
  [ ! -e "$INST/postgres/owner" ]
  grep -qx 'job=111' "$INST/postgres/owner.last"
  [ ! -e "$INST/postgres/stale-locks" ]
}

@test "stale lock, owner gone: another job that is no longer running, or this job without its instance -> moved aside" {
  pg_sif
  stale_lock 59477584 node-07
  echo PREEMPTED >"$FAKE_STATE/sacct-59477584" # squeue no longer knows it
  SLURM_JOB_ID=222 run vk start postgres
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved stale lock $INST/postgres/data/postmaster.pid aside to $INST/postgres/stale-locks/postmaster.pid."*"(its owner job 59477584 (on node-07) is PREEMPTED)"* ]]
  [ "$(head -n 1 "$INST"/postgres/stale-locks/postmaster.pid.*)" = 15 ] # moved, not deleted
  ls "$INST"/postgres/stale-locks/.s.PGSQL.39872.lock.*
  [ "$(stat -c %a "$INST/postgres/stale-locks")" = 700 ]
  grep -qx 'job=222' "$INST/postgres/owner"
  # this job's own postgres was killed (instance gone, lock left): stale as well
  kill_fake() { local i; i="$(cat "$FAKE_STATE/$PGN.init")"; pkill -P "$i" || true; kill "$i" || true; rm -f "$FAKE_STATE/$PGN" "$FAKE_STATE/$PGN.init"; }
  kill_fake
  [ -e "$INST/postgres/data/postmaster.pid" ]
  SLURM_JOB_ID=222 run vk start postgres
  [ "$status" -eq 0 ]
  [[ "$output" == *"(its owner is this job (222 on $(hostname -s)) and no postgres instance runs here)"* ]]
  [ "$(ls "$INST"/postgres/stale-locks/ | grep -c '^postmaster.pid')" -ge 1 ]
  # squeue still lists a finished job (COMPLETED within MinJobAge): stale
  kill_fake
  stale_lock 59478770 node-05
  echo COMPLETED >"$FAKE_STATE/squeue-59478770"
  SLURM_JOB_ID=223 run vk start postgres
  [ "$status" -eq 0 ]
  [[ "$output" == *"its owner job 59478770 (on node-05) is COMPLETED"* ]]
}

@test "stale lock, owner job RUNNING or of unknown state -> refuse; nothing moved, no instance started" {
  pg_sif
  stale_lock 333 node-05
  echo RUNNING >"$FAKE_STATE/squeue-333"
  : >"$FAKE_APPTAINER_LOG"
  SLURM_JOB_ID=444 run vk start postgres
  [ "$status" -ne 0 ]
  [[ "$output" == *"postgres: not starting: postgres was started by job 333 on node-05, which is RUNNING"* ]]
  [[ "$output" == *"Two postmasters must never use $INST/postgres/data"* ]]
  [ -e "$INST/postgres/data/postmaster.pid" ]
  [ -e "$INST/postgres/run/.s.PGSQL.39872.lock" ]
  [ ! -e "$INST/postgres/stale-locks" ]
  grep -qx 'job=333' "$INST/postgres/owner"
  [ "$(grep -c 'instance run' "$FAKE_APPTAINER_LOG")" -eq 0 ]
  rm -f "$FAKE_STATE/squeue-333" # neither squeue nor sacct know it
  SLURM_JOB_ID=444 run vk start postgres
  [ "$status" -ne 0 ]
  [[ "$output" == *"started by job 333 on node-05, whose state is unknown"* ]]
  # owner running elsewhere and no lock yet (a start in progress there): refused too
  rm -f "$INST/postgres/data/postmaster.pid"
  echo RUNNING >"$FAKE_STATE/squeue-333"
  SLURM_JOB_ID=444 run vk start postgres
  [ "$status" -ne 0 ]
  [[ "$output" == *"which is RUNNING"* ]]
  [ "$(grep -c 'instance run' "$FAKE_APPTAINER_LOG")" -eq 0 ]
}

@test "stale lock without an owner record (visionkb < 0.1.9) -> refuse with the exact command; that command clears it" {
  pg_sif
  stale_lock "" ""
  SLURM_JOB_ID=555 run vk start postgres
  [ "$status" -ne 0 ]
  [[ "$output" == *"$INST/postgres/data/postmaster.pid exists and there is no owner record"* ]]
  [[ "$output" == *"squeue -u $(id -un)"* ]]
  cmd="$(grep -E "^ +mkdir -p '.*/stale-locks' && mv '.*/postmaster.pid' '.*/stale-locks/postmaster.pid.manual-[0-9TZ]+'$" <<<"$output" | sed 's/^ *//')"
  [ -n "$cmd" ]
  [ -e "$INST/postgres/data/postmaster.pid" ]
  bash -c "$cmd"
  [ ! -e "$INST/postgres/data/postmaster.pid" ]
  SLURM_JOB_ID=555 run vk start postgres
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved stale lock $INST/postgres/run/.s.PGSQL.39872.lock aside"* ]]
  grep -qx 'job=555' "$INST/postgres/owner"
}

@test "start fails fast when the server exits but its instance stays up: errors since this start, instance stopped" {
  pg_sif
  log="$TMP/aconf/instances/logs/$(hostname)/$(id -un)/$PGN.err"
  mkdir -p "$(dirname "$log")"
  echo "FATAL:  an old error from an earlier start" >"$log"
  : >"$FAKE_STATE/server-exits-postgres"
  t0=$SECONDS
  VISIONKB_START_TIMEOUT=1800 SLURM_JOB_ID=666 run vk start postgres
  [ "$status" -ne 0 ]
  ((SECONDS - t0 < 30))
  [[ "$output" == *"postgres server process exited during start-up (its instance was still up; stopped it)"* ]]
  [[ "$output" == *'FATAL:  lock file "postmaster.pid" already exists'* ]]
  [[ "$output" == *"HINT:  Is another postmaster (PID 15) running"* ]]
  [[ "$output" == *"checks the lock owner"* ]]
  [[ "$output" != *"an old error"* ]]
  [ ! -e "$FAKE_STATE/$PGN" ]
  # the same for another service (neo4j: no server, cypher fails)
  rm -f "$FAKE_STATE/server-exits-postgres"
  loaded_r1
  : >"$FAKE_STATE/server-exits-neo4j"
  VISIONKB_START_TIMEOUT=1800 SLURM_JOB_ID=666 run vk start neo4j
  [ "$status" -ne 0 ]
  [[ "$output" == *"neo4j server process exited during start-up"* ]]
}

@test "start replaces an instance that is up without its server process (instead of 'already running')" {
  pg_sif
  SLURM_JOB_ID=777 vk start postgres
  i="$(cat "$FAKE_STATE/$PGN.init")"
  pkill -P "$i" || true
  kill "$i" || true
  nohup sleep 100000 >/dev/null 2>&1 </dev/null 3>&- & # the instance's init, now without a child
  echo $! >"$FAKE_STATE/$PGN.init"
  SLURM_JOB_ID=777 run vk start postgres
  [ "$status" -eq 0 ]
  [[ "$output" == *"start postgres: its instance is up but the server process exited; stopping the instance"* ]]
  [[ "$output" == *"its owner is this job (777"* ]]
  pgrep -P "$(cat "$FAKE_STATE/$PGN.init")" >/dev/null
  SLURM_JOB_ID=777 run vk start postgres
  [[ "$output" == *"start postgres: already running"* ]]
}

@test "sbatch: TERM during a long foreground step (ensure-loaded, start) stops the step and the instances at once" {
  local stepname pid rc t0
  mkdir -p "$TMP/stub/bin"
  for stepname in ensure-loaded start; do
    rm -f "$TMP/stub.log" "$TMP/sleep.pid"
    cat >"$TMP/stub/bin/visionkb" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/stub.log"
if [[ "\$1" == "$stepname" ]]; then sleep 3001 & echo \$! >"$TMP/sleep.pid"; wait; fi
exit 0
EOF
    chmod +x "$TMP/stub/bin/visionkb"
    VISIONKB_DEPLOY_REPO="$TMP/stub" bash "$REPO/slurm/visionkb.sbatch" >"$TMP/job.out" 2>&1 3>&- &
    pid=$!
    for _ in $(seq 100); do grep -qx "$stepname" "$TMP/stub.log" 2>/dev/null && break; sleep 0.1; done
    sleep 0.5
    t0=$SECONDS
    kill -TERM "$pid"
    rc=0
    wait "$pid" || rc=$?
    ((SECONDS - t0 <= 5))
    [ "$rc" -eq 0 ]
    [ "$(tail -n 1 "$TMP/stub.log")" = stop ]
    grep -q "received TERM" "$TMP/job.out"
    grep -q "interrupting the running step" "$TMP/job.out"
    [ -s "$TMP/sleep.pid" ]
    run kill -0 "$(cat "$TMP/sleep.pid")" # the step's child got the group TERM too
    [ "$status" -ne 0 ]
    rm -f "$TMP/sleep.pid"
  done
}
