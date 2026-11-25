#!/usr/bin/env bash
# Experiment 1: baseline sweep of both stacks (default TCP config). See README for prereqs.
# Run: bash benchmarks/run-benchmarks.sh   (SMOKE=1 for a quick pipeline check)
set -uo pipefail

# Config (edit for your machine)
SERN_URL="http://localhost:3001"
MERN_URL="http://localhost:3002"
SCRIPT="benchmarks/workload.js"
OUT_DIR="${OUT_DIR:-benchmarks/results}"
DURATION="30s"

OPERATIONS=(create update read mixed)
SCALING_LEVELS=(500 1000 1500 2000 2500 3000)
SCALING_REPS=6
BREAKING_OP="create"
BREAKING_LEVELS=(4000 5000 6000 8000 10000)
BREAKING_REPS=3

if [ "${SMOKE:-0}" = "1" ]; then
  SCALING_LEVELS=(500)
  SCALING_REPS=1
  BREAKING_LEVELS=()
  echo "SMOKE mode: all operations, 1 rep at 500 VU, no breaking sweep"
fi

SERN_SERVER_DIR="sern/server"
SERN_DB="sern/server/prisma/dev.db"
SERN_SNAPSHOT="baseline/sern.db"

MERN_DB="mern-thesis"
MERN_DUMP="baseline/mern.dump"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || { echo "cannot cd to repo root"; exit 1; }
echo "working dir: $(pwd)"

command -v k6   >/dev/null || { echo "k6 not found on PATH"; exit 1; }
command -v curl >/dev/null || { echo "curl not found"; exit 1; }
mkdir -p "${OUT_DIR}"

stop_sern() {
  local pids
  pids=$(lsof -ti tcp:3001 2>/dev/null || true)
  [ -n "${pids}" ] && kill ${pids} 2>/dev/null || true
  sleep 1
  pids=$(lsof -ti tcp:3001 2>/dev/null || true)
  [ -n "${pids}" ] && kill -9 ${pids} 2>/dev/null || true
}

start_sern() {
  ( cd "${SERN_SERVER_DIR}" && exec npx tsx --env-file=.env src/index.ts ) >/tmp/sern-server.log 2>&1 &
}

wait_health() {
  local url="$1" tries=0
  until curl -sf "${url}/health" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ ${tries} -gt 60 ]; then echo "!! ${url} not healthy after 60s (see /tmp/sern-server.log)"; return 1; fi
    sleep 1
  done
}

reset_sern() {
  stop_sern
  rm -f "${SERN_DB}" "${SERN_DB}-wal" "${SERN_DB}-shm"
  cp "${SERN_SNAPSHOT}" "${SERN_DB}"
  echo "   [reset] Post-rader: $(sqlite3 "${SERN_DB}" 'SELECT count(*) FROM Post;')"
  start_sern
  wait_health "${SERN_URL}"
}

reset_mern() {
  mongorestore --quiet --drop --nsInclude="${MERN_DB}.*" "${MERN_DUMP}" >/dev/null 2>&1
}

run_one() {
  local stack="$1" url="$2" op="$3" vus="$4" rep="$5"
  local out="${OUT_DIR}/${stack}-${op}-vus${vus}-rep${rep}.json"
  echo ">> ${stack}  op=${op}  VUS=${vus}  rep=${rep}"
  if [ "${stack}" = "sern" ]; then reset_sern || return; else reset_mern; fi
  sleep 3
  k6 run -e BASE_URL="${url}" -e VUS="${vus}" -e OP="${op}" -e DURATION="${DURATION}" \
         --summary-export "${out}" "${SCRIPT}" >/dev/null 2>&1 || true
  [ -s "${out}" ] || echo "   !! no summary written for ${stack}/${op}/vus${vus}/rep${rep}"
}

sweep() {
  local stack="$1" url="$2"
  if [ ${#OPERATIONS[@]} -gt 0 ] && [ ${#SCALING_LEVELS[@]} -gt 0 ]; then
    for op in "${OPERATIONS[@]}"; do
      for vus in "${SCALING_LEVELS[@]}"; do
        for rep in $(seq 1 "${SCALING_REPS}"); do run_one "${stack}" "${url}" "${op}" "${vus}" "${rep}"; done
      done
    done
  fi
  if [ ${#BREAKING_LEVELS[@]} -gt 0 ]; then
    for vus in "${BREAKING_LEVELS[@]}"; do
      for rep in $(seq 1 "${BREAKING_REPS}"); do run_one "${stack}" "${url}" "${BREAKING_OP}" "${vus}" "${rep}"; done
    done
  fi
}

echo "=== SERN sweep (script manages the :3001 server) ==="
sweep sern "${SERN_URL}"
stop_sern

echo "=== MERN sweep (your :3002 server must be running) ==="
curl -sf "${MERN_URL}/health" >/dev/null || { echo "MERN server not reachable on :3002, start it first"; exit 1; }
sweep mern "${MERN_URL}"

echo "All runs complete. Summaries in ${OUT_DIR}/. Aggregate with: python3 aggregate.py"
