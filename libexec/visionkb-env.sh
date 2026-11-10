# shellcheck shell=bash
# Shared helpers for bin/visionkb and bin/visionkb-k8s (sourced, not executed).

# load_env_file FILE: read KEY=VALUE lines without executing them (same format as docker compose
# env files: optional `export`, optional surrounding quotes, # comments). Variables that are already
# set keep their value, so the caller's environment wins over the file.
load_env_file() {
  local file="$1" line key val n=0
  [[ -r "$file" ]] || die "cannot read env file $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[2]}"
      val="${BASH_REMATCH[3]}"
      val="${val%"${val##*[![:space:]]}"}"
      if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
      fi
      if [[ -z "${!key+x}" ]]; then
        export "$key=$val"
      fi
    else
      die "$file:$n: expected KEY=VALUE"
    fi
  done <"$file"
}

# load_versions_env FILE: load_env_file for versions.env, plus the bundle pin rule: versions.env's
# VISIONKB_KG_BUNDLE_SHA256 pins the bundle of versions.env's own VISIONKB_KG_RELEASE. When the environment or
# the env file selects another default release without setting its own VISIONKB_KG_BUNDLE_SHA256, the pin
# does not apply (it is cleared). An empty value means no pin.
load_versions_env() {
  local file="$1" sha_preset=0 pinned_release
  [[ -n "${VISIONKB_KG_BUNDLE_SHA256+x}" ]] && sha_preset=1
  load_env_file "$file"
  pinned_release="$(sed -n 's/^VISIONKB_KG_RELEASE=//p' "$file" | tail -n 1)"
  if ((sha_preset == 0)) && [[ "${VISIONKB_KG_RELEASE:-}" != "$pinned_release" ]]; then
    export VISIONKB_KG_BUNDLE_SHA256=""
  fi
  local sha="${VISIONKB_KG_BUNDLE_SHA256:-}"
  sha="${sha,,}"
  [[ -z "$sha" || "$sha" =~ ^[0-9a-f]{64}$ ]] || die "VISIONKB_KG_BUNDLE_SHA256 must be a sha256 hex digest (got '$sha')"
  export VISIONKB_KG_BUNDLE_SHA256="$sha"
}

# check_release_id ID: contracts section 1 (visionkb-YYYY.MM.N)
check_release_id() { [[ "$1" =~ ^visionkb-[0-9]{4}\.[0-9]{2}\.[0-9]+$ ]] || die "invalid release id '$1' (visionkb-YYYY.MM.N)"; }

# image_parts REF -> prints "name tag digest" (tag/digest may be "-"), e.g.
#   neo4j:2026.10.1-community@sha256:ab.. -> "neo4j 2026.10.1-community sha256:ab.."
image_parts() {
  local ref="$1" name tag="-" digest="-"
  name="${ref%%@*}"
  [[ "$ref" == *@* ]] && digest="${ref#*@}"
  if [[ "${name##*/}" == *:* ]]; then
    tag="${name##*:}"
    name="${name%:*}"
  fi
  printf '%s %s %s\n' "$name" "$tag" "$digest"
}
