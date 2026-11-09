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
