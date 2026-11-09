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
