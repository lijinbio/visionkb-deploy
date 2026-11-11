#!/usr/bin/env bash
# Run the VisionKB stack (PostgreSQL, Neo4j, API) inside one Slurm allocation, as apptainer instances.
#
#   sbatch --partition=<partition> --account=<account> slurm/visionkb.sbatch [--env-file FILE] [--instance NAME]
#
# Neo4j stores are node-local (VISIONKB_STORE_DIR, default $TMPDIR or /tmp/$USER/visionkb/<instance>) and vanish
# with the allocation: the job first runs `visionkb ensure-loaded`, which re-imports the current release from its
# recorded source when its store is not on this node (minutes for a large release).
# Services bind 127.0.0.1 on the compute node; reach them with an SSH tunnel (printed in the job log, see
# docs/hpc3.md). The job health-checks every VISIONKB_HEALTH_INTERVAL seconds and stops the instances
# cleanly when Slurm signals the end of the time limit (--signal below) or on scancel.
# Every VISIONKB_CONTROL_POLL seconds (default 5, at most 10) it processes restart requests from
# `visionkb request-restart SERVICE...` (any node) in this batch step, so restarted instances stay in the job.
#SBATCH --job-name=visionkb
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=1-00:00:00
#SBATCH --signal=B:TERM@180
#SBATCH --output=visionkb-%j.out
set -euo pipefail

# Under sbatch, BASH_SOURCE points at a spooled copy; use the submit dir or VISIONKB_DEPLOY_REPO.
repo="${VISIONKB_DEPLOY_REPO:-${SLURM_SUBMIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}"
[[ -x "$repo/bin/visionkb" ]] || {
  echo "visionkb.sbatch: bin/visionkb not found under $repo; submit from the repo or set VISIONKB_DEPLOY_REPO" >&2
  exit 1
}
vk=("$repo/bin/visionkb" "$@")
interval="${VISIONKB_HEALTH_INTERVAL:-300}"
poll="${VISIONKB_CONTROL_POLL:-5}"
[[ "$poll" =~ ^[0-9]+$ ]] && ((poll >= 1 && poll <= 10)) || poll=5

stopping=0
shutdown() {
  ((stopping)) && return
  stopping=1
  echo "visionkb.sbatch: $(date -u +%FT%TZ) stopping"
  "${vk[@]}" stop || true
}
trap shutdown TERM INT EXIT

# Keep JVM/apptainer scratch on node-local disk when Slurm provides one.
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-${TMPDIR:-/tmp}}"

echo "visionkb.sbatch: job ${SLURM_JOB_ID:-?} on $(hostname -s), $(date -u +%FT%TZ)"
"${vk[@]}" config
"${vk[@]}" ensure-loaded
"${vk[@]}" start
"${vk[@]}" health || echo "visionkb.sbatch: WARNING: health check failed after start"

# tunnel hint: the API port, plus the web port when web is in VISIONKB_SERVICES
"${vk[@]}" tunnel-hint "$(hostname -s)" | sed 's/^/visionkb.sbatch: /'

next_health=$((SECONDS + interval))
while true; do
  sleep "$poll" &
  wait $! || true
  ((stopping)) && break
  # restart requests (data files in <instance>/control/requests), performed here in the batch step
  "${vk[@]}" process-requests || echo "visionkb.sbatch: $(date -u +%FT%TZ) processing restart requests failed"
  ((stopping)) && break
  if ((SECONDS >= next_health)); then
    next_health=$((SECONDS + interval))
    if ! "${vk[@]}" health; then
      echo "visionkb.sbatch: $(date -u +%FT%TZ) health check failed"
    fi
  fi
done
