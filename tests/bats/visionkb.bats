#!/usr/bin/env bats
# Argument parsing, settings precedence and the bundle commands of bin/visionkb.
# Needs bash, python3 (>= 3.9); no apptainer (commands that need it are not run here).

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  VK="$REPO/bin/visionkb"
  TMP="$(mktemp -d)"
  unset VISIONKB_ENV_FILE VISIONKB_DATA_ROOT VISIONKB_WORK_DIR VISIONKB_INSTANCE VISIONKB_KG_RELEASE \
    VISIONKB_DEPLOY_DIR VISIONKB_RELEASES_DIR VISIONKB_BUNDLES_DIR VISIONKB_SERVICES VISIONKB_API_PORT \
    VISIONKB_KG_BUNDLE_SHA256 VISIONKB_MCP_IMAGE VISIONKB_SKILLS_RELEASE VISIONKB_IMAGES_DIR
  cat >"$TMP/test.env" <<EOF
# comment
VISIONKB_DATA_ROOT=$TMP/data
VISIONKB_WORK_DIR=$TMP/work
VISIONKB_RELEASES_DIR=$TMP/releases
export VISIONKB_API_PORT="9999"
VISIONKB_SERVICES='postgres neo4j'
EOF
}

teardown() {
  chmod -R u+w "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}

make_fixture() { python3 "$REPO/tests/fixtures/make_fixture_release.py" "$TMP/releases" "$1" ${2:+--variant "$2"} >/dev/null; }

@test "help lists every command" {
  run "$VK" --help
  [ "$status" -eq 0 ]
  for c in pull init load-release rollback start stop status health backup restore export-bundle unpack-bundle; do
    [[ "$output" == *"$c"* ]]
  done
}

@test "version" {
  run "$VK" --version
  [ "$status" -eq 0 ]
  [[ "$output" == "visionkb-deploy "* ]]
}

@test "no command exits 2" {
  run "$VK"
  [ "$status" -eq 2 ]
}

@test "unknown command and option are errors" {
  run "$VK" --env-file "$TMP/test.env" frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown command 'frobnicate'"* ]]
  run "$VK" --bogus status
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option --bogus"* ]]
}

@test "env file values, quotes and export are parsed; environment wins" {
  run "$VK" --env-file "$TMP/test.env" config
  [ "$status" -eq 0 ]
  [[ "$output" == *"VISIONKB_API_PORT=9999"* ]]
  [[ "$output" == *"VISIONKB_SERVICES=postgres neo4j"* ]]
  [[ "$output" == *"VISIONKB_DEPLOY_DIR=$TMP/work/visionkb-deploy"* ]]
  [[ "$output" == *"VISIONKB_KG_RELEASE=visionkb-"* ]] # from versions.env
  [[ "$output" == *"VISIONKB_PYTHON=python3"* ]]
  # Neo4j stores default to node-local disk (TMPDIR if absolute, else /tmp/$USER/visionkb/<instance>)
  TMPDIR=relative/tmp run "$VK" --env-file "$TMP/test.env" config
  [[ "$output" == *"VISIONKB_STORE_DIR=/tmp/$(id -un)/visionkb/default"* ]]
  [[ "$output" == *"store_fs="* ]]
  # an absolute TMPDIR on local disk is used (a TMPDIR on a network filesystem is ignored)
  local_tmp="$(mktemp -d /tmp/vkbats.XXXXXX)"
  TMPDIR="$local_tmp" run "$VK" --env-file "$TMP/test.env" config
  rmdir "$local_tmp"
  [[ "$output" == *"VISIONKB_STORE_DIR=$local_tmp/visionkb/default"* ]]
  VISIONKB_API_PORT=1234 run "$VK" --env-file "$TMP/test.env" config
  [[ "$output" == *"VISIONKB_API_PORT=1234"* ]]
}

@test "env file is not executed and bad lines are rejected with a line number" {
  printf 'VISIONKB_WORK_DIR=$(touch %s/pwned)\nnot a setting\n' "$TMP" >"$TMP/bad.env"
  run "$VK" --env-file "$TMP/bad.env" config
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad.env:2: expected KEY=VALUE"* ]]
  [ ! -e "$TMP/pwned" ]
}

@test "instance names are validated and reserved names refused" {
  run "$VK" --env-file "$TMP/test.env" --instance 'Bad_Name' config
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid instance name"* ]]
  run "$VK" --env-file "$TMP/test.env" --instance images config
  [ "$status" -eq 1 ]
  [[ "$output" == *"reserved"* ]]
}

@test "ports must be numbers and services must be known" {
  VISIONKB_PG_PORT=abc run "$VK" --env-file "$TMP/test.env" config
  [ "$status" -eq 1 ]
  [[ "$output" == *"VISIONKB_PG_PORT must be a number"* ]]
  VISIONKB_SERVICES="neo4j redis" run "$VK" --env-file "$TMP/test.env" config
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown service 'redis'"* ]]
  run "$VK" --env-file "$TMP/test.env" start redis
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown service 'redis'"* ]]
}

@test "release ids are validated before anything runs" {
  run "$VK" --env-file "$TMP/test.env" load-release not-a-release
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid release id"* ]]
  run "$VK" --env-file "$TMP/test.env" rollback visionkb-2026.1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid release id"* ]]
  run "$VK" --env-file "$TMP/test.env" load-release a b
  [ "$status" -eq 1 ]
  run "$VK" --env-file "$TMP/test.env" load-release visionkb-0000.01.1 --from x --bundle y.tar
  [ "$status" -eq 1 ]
  [[ "$output" == *"not both"* ]]
}

@test "ensure-loaded and --expected-ids argument checks" {
  run "$VK" --env-file "$TMP/test.env" ensure-loaded --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: visionkb ensure-loaded"* ]]
  run "$VK" --env-file "$TMP/test.env" load-release visionkb-0000.01.1 --expected-ids
  [ "$status" -ne 0 ]
}

@test "restore needs --yes" {
  mkdir -p "$TMP/b" && echo x >"$TMP/b/proposals.pgdump"
  run "$VK" --env-file "$TMP/test.env" restore "$TMP/b"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--yes"* ]]
}

@test "init writes secrets with mode 600 and keeps them on re-run" {
  run "$VK" --env-file "$TMP/test.env" --instance t1 init
  [ "$status" -eq 0 ]
  s="$TMP/work/visionkb-deploy/t1/secrets"
  for f in neo4j_password pg_password pg_dsn api_tokens api_token_read; do
    [ -s "$s/$f" ]
    [ "$(stat -c %a "$s/$f")" = 600 ]
  done
  [ "$(stat -c %a "$TMP/work/visionkb-deploy/t1")" = 700 ]
  grep -q '^postgresql://visionkb:[A-Za-z0-9]\{32\}@127.0.0.1:5432/visionkb$' "$s/pg_dsn"
  [ "$(cut -f2 "$s/api_tokens")" = read ]
  before="$(cat "$s/neo4j_password")"
  run "$VK" --env-file "$TMP/test.env" --instance t1 init
  [ "$status" -eq 0 ]
  [[ "$output" == *"keeping existing neo4j_password"* ]]
  [ "$(cat "$s/neo4j_password")" = "$before" ]
}

@test "verify-release accepts a fixture and rejects a tampered one" {
  make_fixture visionkb-0000.01.1
  run "$VK" --env-file "$TMP/test.env" verify-release visionkb-0000.01.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"status: ok"* ]]
  echo tamper >>"$TMP/releases/visionkb-0000.01.1/neo4j-import/nodes_Gene.csv"
  run "$VK" --env-file "$TMP/test.env" verify-release "$TMP/releases/visionkb-0000.01.1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"nodes_Gene.csv"* ]]
}

@test "export-bundle then unpack-bundle into another directory" {
  make_fixture visionkb-0000.01.2 2
  run "$VK" --env-file "$TMP/test.env" export-bundle visionkb-0000.01.2 --out "$TMP/bundles"
  [ "$status" -eq 0 ]
  [ -s "$TMP/bundles/visionkb-0000.01.2.tar" ]
  [[ "$output" == *"sha256sum -c visionkb-0000.01.2.tar.sha256"* ]]
  (cd "$TMP/bundles" && sha256sum -c visionkb-0000.01.2.tar.sha256)
  run "$VK" --env-file "$TMP/test.env" unpack-bundle "$TMP/bundles/visionkb-0000.01.2.tar" --dest "$TMP/elsewhere"
  [ "$status" -eq 0 ]
  [[ "$output" == *"action: unpacked"* ]]
  run "$VK" --env-file "$TMP/test.env" verify-release "$TMP/elsewhere/visionkb-0000.01.2"
  [ "$status" -eq 0 ]
}

@test "unpack-bundle refuses a bundle whose sha256 does not match" {
  make_fixture visionkb-0000.01.1
  "$VK" --env-file "$TMP/test.env" export-bundle visionkb-0000.01.1 --out "$TMP/bundles" >/dev/null
  printf '%064d  visionkb-0000.01.1.tar\n' 0 >"$TMP/bundles/visionkb-0000.01.1.tar.sha256"
  run "$VK" --env-file "$TMP/test.env" unpack-bundle "$TMP/bundles/visionkb-0000.01.1.tar" --dest "$TMP/x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256"* ]]
  [ ! -e "$TMP/x/visionkb-0000.01.1" ]
}

# A fake apptainer on PATH: logs its arguments; `pull --force DEST SRC` creates DEST.
fake_apptainer() {
  mkdir -p "$TMP/fakebin"
  cat >"$TMP/fakebin/apptainer" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_APPTAINER_LOG"
if [[ "$1" == pull ]]; then : >"$3"; fi
EOF
  chmod +x "$TMP/fakebin/apptainer"
  export FAKE_APPTAINER_LOG="$TMP/apptainer.log"
  export PATH="$TMP/fakebin:$PATH"
}

@test "pull mcp pulls the MCP server image by digest; plain pull and start leave it out" {
  fake_apptainer
  run "$VK" --env-file "$TMP/test.env" pull mcp
  [ "$status" -eq 0 ]
  grep -qx 'pull --force .*/images/mcp-visionkb-kg_0.0.1_2425d3138146.sif.partial docker://ghcr.io/lijinbio/mcp-visionkb-kg@sha256:2425d3138146d48236dde432aa1094d6a824c0529da82359355b886777d549d4' "$FAKE_APPTAINER_LOG"
  sif="$TMP/work/visionkb-deploy/images/mcp-visionkb-kg_0.0.1_2425d3138146.sif"
  [ -f "$sif" ]
  grep -qx 'ghcr.io/lijinbio/mcp-visionkb-kg:0.0.1@sha256:2425d3138146d48236dde432aa1094d6a824c0529da82359355b886777d549d4' "$sif.ref"
  run "$VK" --env-file "$TMP/test.env" pull mcp
  [[ "$output" == *"exists (use --force to re-pull)"* ]]
  : >"$FAKE_APPTAINER_LOG"
  run "$VK" --env-file "$TMP/test.env" pull
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pull ' "$FAKE_APPTAINER_LOG")" -eq 2 ] # VISIONKB_SERVICES='postgres neo4j' in test.env
  ! grep -q mcp-visionkb-kg "$FAKE_APPTAINER_LOG"
  run "$VK" --env-file "$TMP/test.env" start mcp
  [ "$status" -eq 1 ]
  run "$VK" --env-file "$TMP/test.env" config
  [[ "$output" == *"VISIONKB_MCP_IMAGE=ghcr.io/lijinbio/mcp-visionkb-kg:0.0.1@sha256:2425d313"* ]]
  [[ "$output" == *"VISIONKB_SKILLS_RELEASE=v0.2.1"* ]]
}

@test "the versions.env bundle sha pins only its own release" {
  run "$VK" --env-file "$TMP/test.env" config
  [ "$status" -eq 0 ]
  [[ "$output" == *"VISIONKB_KG_RELEASE=visionkb-2026.11.0"* ]]
  [[ "$output" == *"VISIONKB_KG_BUNDLE_SHA256=0af5a709e65aee1d04637c022f51364537b04a9f2c2fb65c489d273564bef66d"* ]]
  echo 'VISIONKB_KG_RELEASE=visionkb-0000.01.1' >>"$TMP/test.env"
  run "$VK" --env-file "$TMP/test.env" config
  [[ "$output" == *$'\nVISIONKB_KG_BUNDLE_SHA256=\n'* ]] # another default release without its own sha: no pin
  VISIONKB_KG_BUNDLE_SHA256=ABC run "$VK" --env-file "$TMP/test.env" config
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a sha256 hex digest"* ]]
}

@test "unpack-bundle and load-release --bundle check the pinned bundle sha256 (match, mismatch, other release)" {
  fake_apptainer
  make_fixture visionkb-0000.01.1
  "$VK" --env-file "$TMP/test.env" export-bundle visionkb-0000.01.1 --out "$TMP/bundles" >/dev/null
  tar="$TMP/bundles/visionkb-0000.01.1.tar"
  sha="$(sha256sum "$tar" | cut -d' ' -f1)"
  bad="$(printf 'a%.0s' {1..64})"
  # mismatch: refused before anything is unpacked
  VISIONKB_KG_RELEASE=visionkb-0000.01.1 VISIONKB_KG_BUNDLE_SHA256="$bad" \
    run "$VK" --env-file "$TMP/test.env" unpack-bundle "$tar" --dest "$TMP/x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"!= pinned VISIONKB_KG_BUNDLE_SHA256 $bad"* ]]
  [ ! -e "$TMP/x/visionkb-0000.01.1" ] && [ ! -e "$TMP/x/visionkb-0000.01.1.partial" ]
  # match
  VISIONKB_KG_RELEASE=visionkb-0000.01.1 VISIONKB_KG_BUNDLE_SHA256="$sha" \
    run "$VK" --env-file "$TMP/test.env" unpack-bundle "$tar" --dest "$TMP/x"
  [ "$status" -eq 0 ]
  [[ "$output" == *"action: unpacked"* ]]
  # other release pinned: this bundle is not affected
  VISIONKB_KG_RELEASE=visionkb-0000.01.9 VISIONKB_KG_BUNDLE_SHA256="$bad" \
    run "$VK" --env-file "$TMP/test.env" unpack-bundle "$tar" --dest "$TMP/y"
  [ "$status" -eq 0 ]
  # load-release --bundle with a mismatching pin: no unpack, no load record, apptainer never runs a container
  "$VK" --env-file "$TMP/test.env" init >/dev/null 2>&1
  : >"$FAKE_APPTAINER_LOG"
  VISIONKB_KG_RELEASE=visionkb-0000.01.1 VISIONKB_KG_BUNDLE_SHA256="$bad" \
    run "$VK" --env-file "$TMP/test.env" load-release --bundle "$tar"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pinned VISIONKB_KG_BUNDLE_SHA256"* ]]
  inst="$TMP/work/visionkb-deploy/default"
  [ ! -e "$inst/bundles/visionkb-0000.01.1" ]
  [ ! -e "$inst/neo4j/loaded/visionkb-0000.01.1" ]
  ! grep -q '^exec\|^instance' "$FAKE_APPTAINER_LOG"
}

