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
# Every step (ensure-loaded, start, health, process-requests) runs in the background in its own session while the
# script waits, so TERM/INT is handled at once: the trap stops the running step (TERM to its process group,
# KILL after VISIONKB_STEP_STOP_WAIT s, default 20) and then runs `visionkb stop` (clean postgres shutdown).
# On HPC3 the free* partitions preempt with GraceTime=0 (SIGTERM to the whole job, SIGKILL KillWait=60 s
# later): see docs/hpc3.md.
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

stop_wait="${VISIONKB_STEP_STOP_WAIT:-20}"
[[ "$stop_wait" =~ ^[0-9]+$ ]] && ((stop_wait >= 1 && stop_wait <= 120)) || stop_wait=20

stopping=0
step_pid=""
# step CMD...: run `visionkb CMD...` in its own session (process group = its pid) and wait for it; the wait returns
# as soon as a trapped signal arrives
step() {
  setsid "${vk[@]}" "$@" &
  step_pid=$!
  local rc=0
  wait "$step_pid" || rc=$?
  step_pid=""
  return "$rc"
}
stop_step() {
  local pid="$step_pid" i
  [[ -n "$pid" ]] || return 0
  echo "visionkb.sbatch: $(date -u +%FT%TZ) interrupting the running step (pid $pid)"
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for ((i = 0; i < stop_wait; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "visionkb.sbatch: step still running after ${stop_wait}s; KILL"
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  step_pid=""
}
shutdown() {
  ((stopping)) && return
  stopping=1
  echo "visionkb.sbatch: $(date -u +%FT%TZ) stopping"
  stop_step
  "${vk[@]}" stop || true
}
on_signal() {
  # a second signal during the clean stop is ignored (the stop continues)
  ((stopping)) && return
  echo "visionkb.sbatch: $(date -u +%FT%TZ) received $1"
  shutdown
  exit 0
}
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT
trap shutdown EXIT

# Keep JVM/apptainer scratch on node-local disk when Slurm provides one.
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-${TMPDIR:-/tmp}}"

echo "visionkb.sbatch: job ${SLURM_JOB_ID:-?} on $(hostname -s), $(date -u +%FT%TZ)"
step config
step ensure-loaded
step start
step health || echo "visionkb.sbatch: WARNING: health check failed after start"

# tunnel hint: the API port, plus the web port when web is in VISIONKB_SERVICES
"${vk[@]}" tunnel-hint "$(hostname -s)" | sed 's/^/visionkb.sbatch: /'

next_health=$((SECONDS + interval))
while true; do
  sleep "$poll" &
  wait $! || true
  ((stopping)) && break
  # restart requests (data files in <instance>/control/requests), performed here in the batch step
  step process-requests || echo "visionkb.sbatch: $(date -u +%FT%TZ) processing restart requests failed"
  ((stopping)) && break
  if ((SECONDS >= next_health)); then
    next_health=$((SECONDS + interval))
    if ! step health; then
      echo "visionkb.sbatch: $(date -u +%FT%TZ) health check failed"
    fi
  fi
done
