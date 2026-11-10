#!/usr/bin/env bats
# bin/visionkb-k8s without a cluster: argument parsing, sync check, template rendering, switch --no-apply.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
  # work on a copy so `switch --no-apply` cannot touch the checkout
  cp -r "$REPO/bin" "$REPO/libexec" "$REPO/k8s" "$REPO/src" "$REPO/versions.env" "$TMP/"
  K="$TMP/bin/visionkb-k8s"
  unset VISIONKB_ENV_FILE VISIONKB_K8S_OVERLAY VISIONKB_BUNDLE_URL VISIONKB_BUNDLE_URL_TEMPLATE
}

teardown() { rm -rf "$TMP"; }

@test "help and unknown command" {
  run "$K" help
  [ "$status" -eq 0 ]
  for c in sync render create-secrets apply upload-bundle fetch-bundle load-release switch rollback; do
    [[ "$output" == *"$c"* ]]
  done
  run "$K" frobnicate
  [ "$status" -eq 1 ]
}

@test "overlay must be local-bundle or fetch-bundle" {
  run "$K" --overlay nfs-mount render-template load-release visionkb-2026.11.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"VISIONKB_K8S_OVERLAY must be"* ]]
}

@test "sync --check passes on the committed tree and fails when versions.env changes" {
  run "$K" sync --check
  [ "$status" -eq 0 ]
  sed -i 's/^VISIONKB_API_IMAGE=.*/VISIONKB_API_IMAGE=ghcr.io\/lijinbio\/visionkb-api:9.9.9/' "$TMP/versions.env"
  run "$K" sync --check
  [ "$status" -eq 1 ]
  run "$K" sync
  [ "$status" -eq 0 ]
  grep -q 'newTag: "9.9.9"' "$TMP/k8s/base/kustomization.yaml"
}

@test "render-template fills every placeholder and validates the id" {
  run "$K" render-template load-release visionkb-2026.11.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: visionkb-load-visionkb-2026-11-0"* ]]
  [[ "$output" == *"/bundles/releases/visionkb-2026.11.0"* ]]
  [[ "$output" == *"image: neo4j:2026.10.1-community@sha256:"* ]]
  [[ "$output" != *"__"*"__"* ]]
  run "$K" render-template fetch-bundle visionkb-2026.11.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://downloads.example.org/visionkb/bundles/visionkb-2026.11.0.tar"* ]]
  run "$K" render-template fetch-bundle visionkb-2026.11.0 'https://example.org/b.tar?x=1&y=2'
  [[ "$output" == *"https://example.org/b.tar?x=1&y=2"* ]]
  run "$K" render-template load-release ../etc
  [ "$status" -eq 1 ]
  run "$K" render-template nope visionkb-2026.11.0
  [ "$status" -eq 1 ]
}

@test "switch --no-apply rotates current/previous and rollback swaps back" {
  run "$K" switch visionkb-2026.11.1 --no-apply
  [ "$status" -eq 0 ]
  grep -qx 'VISIONKB_KG_RELEASE=visionkb-2026.11.1' "$TMP/k8s/overlays/local-bundle/release.env"
  grep -qx 'VISIONKB_PREVIOUS_RELEASE=visionkb-2026.11.0' "$TMP/k8s/overlays/local-bundle/release.env"
  run "$K" rollback --no-apply
  [ "$status" -eq 0 ]
  grep -qx 'VISIONKB_KG_RELEASE=visionkb-2026.11.0' "$TMP/k8s/overlays/local-bundle/release.env"
  run "$K" switch visionkb-2026.11.0 --no-apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"already the served release"* ]]
}

@test "upload-bundle checks the outer sha256 before contacting the cluster" {
  mkdir -p "$TMP/b"
  echo data >"$TMP/b/visionkb-2026.11.0.tar"
  printf '%064d  visionkb-2026.11.0.tar\n' 0 >"$TMP/b/visionkb-2026.11.0.tar.sha256"
  VISIONKB_KUBECTL=/nonexistent run "$K" upload-bundle "$TMP/b/visionkb-2026.11.0.tar"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256"* ]]
}

@test "sync writes the bundle sha into the overlays' release.env and --check catches a change" {
  for o in local-bundle fetch-bundle; do
    grep -qx 'VISIONKB_KG_BUNDLE_SHA256=0af5a709e65aee1d04637c022f51364537b04a9f2c2fb65c489d273564bef66d' \
      "$TMP/k8s/overlays/$o/release.env"
  done
  new="$(printf 'b%.0s' {1..64})"
  sed -i "s/^VISIONKB_KG_BUNDLE_SHA256=.*/VISIONKB_KG_BUNDLE_SHA256=$new/" "$TMP/versions.env"
  run "$K" sync --check
  [ "$status" -eq 1 ]
  run "$K" sync
  [ "$status" -eq 0 ]
  grep -qx "VISIONKB_KG_BUNDLE_SHA256=$new" "$TMP/k8s/overlays/local-bundle/release.env"
  grep -qx "VISIONKB_KG_BUNDLE_SHA256=$new" "$TMP/k8s/overlays/fetch-bundle/release.env"
  run "$K" sync --check
  [ "$status" -eq 0 ]
}

@test "switch and rollback carry the pinned sha; the fetch Job gets it only for the pinned release" {
  pin=0af5a709e65aee1d04637c022f51364537b04a9f2c2fb65c489d273564bef66d
  run "$K" --overlay fetch-bundle render-template fetch-bundle visionkb-2026.11.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"value: \"$pin\""* ]]
  run "$K" --overlay fetch-bundle render-template fetch-bundle visionkb-2026.11.1
  [ "$status" -eq 0 ]
  [[ "$output" == *'- name: PIN_SHA256'*'value: ""'* ]]
  run "$K" switch visionkb-2026.11.1 --no-apply
  [ "$status" -eq 0 ]
  grep -qx 'VISIONKB_KG_BUNDLE_SHA256=' "$TMP/k8s/overlays/local-bundle/release.env"
  run "$K" rollback --no-apply
  [ "$status" -eq 0 ]
  grep -qx "VISIONKB_KG_BUNDLE_SHA256=$pin" "$TMP/k8s/overlays/local-bundle/release.env"
  # release.env and versions.env disagreeing on the pinned release is an error
  sed -i 's/^VISIONKB_KG_BUNDLE_SHA256=.*/VISIONKB_KG_BUNDLE_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/' \
    "$TMP/k8s/overlays/fetch-bundle/release.env"
  run "$K" --overlay fetch-bundle render-template fetch-bundle visionkb-2026.11.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"differs between versions.env"* ]]
}

@test "upload-bundle refuses the pinned release with another sha before contacting the cluster" {
  mkdir -p "$TMP/b"
  for r in visionkb-2026.11.0 visionkb-2026.11.1; do
    echo data >"$TMP/b/$r.tar"
    (cd "$TMP/b" && sha256sum "$r.tar" >"$r.tar.sha256")
  done
  VISIONKB_KUBECTL=/nonexistent run "$K" upload-bundle "$TMP/b/visionkb-2026.11.0.tar"
  [ "$status" -eq 1 ]
  [[ "$output" == *"!= pinned VISIONKB_KG_BUNDLE_SHA256 0af5a709"* ]]
  [[ "$output" != *"kubectl not found"* ]]
  # another release: the sha check passes and the command only stops at the (missing) kubectl
  VISIONKB_KUBECTL=/nonexistent run "$K" upload-bundle "$TMP/b/visionkb-2026.11.1.tar"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256 ok"* && "$output" == *"kubectl not found"* ]]
}

