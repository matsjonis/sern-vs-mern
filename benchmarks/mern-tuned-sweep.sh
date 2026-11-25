#!/usr/bin/env bash
# Experiment 3: MERN-only re-run under the tuned TCP config, writing to results-tuned/
# (used when mongod needs a fresh restart mid-series). Guards against mongod dying mid-run.
# Run: start mongod (rs0) + a fresh MERN server (LISTEN_BACKLOG=4096), then
#      caffeinate -i bash benchmarks/mern-tuned-sweep.sh
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." || { echo "cannot cd to repo root"; exit 1; }
echo "working dir: $(pwd)"

MERN_URL="http://localhost:3002"
SCRIPT="benchmarks/workload.js"
MERN_DB="mern-thesis"
MERN_DUMP="baseline/mern.dump"
DURATION="30s"
OUT="benchmarks/results-tuned"
OPERATIONS=(read create update mixed)
SCALING_LEVELS=(500 1000 1500 2000 2500 3000)
SCALING_REPS=6
BREAKING_LEVELS=(4000 5000 6000 8000 10000)
BREAKING_REPS=3
mkdir -p "${OUT}"

command -v k6 >/dev/null || { echo "k6 not found"; exit 1; }

echo "Preflight: can the MERN server actually query MongoDB?"
curl -sf "${MERN_URL}/health" >/dev/null 2>&1 || { echo "!! MERN server not reachable on :3002, start it first"; exit 1; }
probe=$(curl -s --max-time 10 "${MERN_URL}/api/posts?page=1&pageSize=1" || true)
echo "${probe}" | grep -q '"data"' || { echo "!! /api/posts did not return data, MongoDB not reachable from the server."; echo "   Fix mongod/replica set, restart the MERN server, and retry.  got: ${probe:0:160}"; exit 1; }
echo "   OK, server reachable and querying MongoDB."

echo "Caching sudo (somaxconn)"; sudo -v || exit 1
ORIG_SC=$(sysctl -n kern.ipc.somaxconn)
sudo sysctl -w kern.ipc.somaxconn=4096 >/dev/null
echo "somaxconn ${ORIG_SC} to 4096  (restore later: sudo sysctl -w kern.ipc.somaxconn=${ORIG_SC})"

abort(){ echo "$1"; sudo sysctl -w kern.ipc.somaxconn="${ORIG_SC}" >/dev/null; exit 1; }
reset_mern(){ mongorestore --quiet --drop --nsInclude="${MERN_DB}.*" "${MERN_DUMP}" >/dev/null 2>&1; }
failpct(){ python3 - "$1" <<'PY'
import json,sys
try: print(f'{json.load(open(sys.argv[1]))["metrics"]["http_req_failed"]["value"]*100:.2f}')
except Exception: print("0")
PY
}

run_one(){
  local op="$1" vus="$2" rep="$3"
  local out="${OUT}/mern-${op}-vus${vus}-rep${rep}.json"
  echo ">> mern op=${op} VUS=${vus} rep=${rep}"
  reset_mern; sleep 2
  k6 run -e BASE_URL="${MERN_URL}" -e VUS="${vus}" -e OP="${op}" -e DURATION="${DURATION}" \
     --summary-export "${out}" "${SCRIPT}" >/dev/null 2>&1 || true
  local fp; fp=$(failpct "${out}"); echo "   fail=${fp}%"
  # legitimate MERN fail rate peaks ~42% (update @3000); ~99% means the DB is gone
  if python3 -c "import sys; sys.exit(0 if ${fp:-0}>=99 else 1)"; then
    abort "!! Run failed ${fp}%, MongoDB appears unreachable (mongod likely died). Restart mongod + the MERN server, then re-run."
  fi
}

for op in "${OPERATIONS[@]}"; do
  for vus in "${SCALING_LEVELS[@]}"; do
    for rep in $(seq 1 ${SCALING_REPS}); do run_one "${op}" "${vus}" "${rep}"; done
  done
done
for vus in "${BREAKING_LEVELS[@]}"; do
  for rep in $(seq 1 ${BREAKING_REPS}); do run_one "create" "${vus}" "${rep}"; done
done

sudo sysctl -w kern.ipc.somaxconn="${ORIG_SC}" >/dev/null
echo ""; echo "MERN tuned sweep done. somaxconn restored to ${ORIG_SC}."
echo "Re-aggregate:  cd benchmarks && python3 aggregate.py results-tuned"
