#!/usr/bin/env bash
# Experiment 4: MERN update remedy sweep. Sweeps the update workload in three modes
# (prisma, raw, raw_include) at 500-3000 VU x 6 reps under the tuned config.
# A short prisma control confirms the instrumented server reproduces the baseline;
# raw and raw_include are interleaved per repetition. Each run verifies the 100k
# baseline, measures transaction aborts, and records a missing summary as ERR (never 0%).
# Run: start mongod (rs0) + a fresh MERN server (LISTEN_BACKLOG=4096), then
#      caffeinate -i bash benchmarks/mern-update-sweep.sh
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." || { echo "cannot cd to repo root"; exit 1; }
echo "working dir: $(pwd)"

MERN_URL="http://localhost:3002"
SCRIPT="benchmarks/workload.js"
MERN_DB="mern-thesis"
MERN_DUMP="baseline/mern.dump"
DURATION="30s"
OUT="benchmarks/results-mern-update"
MODES=(raw raw_include)
LEVELS=(500 1000 1500 2000 2500 3000)
REPS=6
CONTROL_LEVELS=(1500 3000)
CONTROL_REPS=2
EXPECT_POSTS=100000
mkdir -p "${OUT}"
CSV="${OUT}/runs.csv"
echo "mode,vus,rep,fail_pct,p95_ms,throughput_rps,aborts" > "${CSV}"

command -v k6 >/dev/null || { echo "k6 not found"; exit 1; }

echo "Preflight: can the MERN server actually query MongoDB?"
curl -sf "${MERN_URL}/health" >/dev/null 2>&1 || { echo "!! MERN server not reachable on :3002, start it first"; exit 1; }
probe=$(curl -s --max-time 10 "${MERN_URL}/api/posts?page=1&pageSize=1" || true)
echo "${probe}" | grep -q '"data"' || { echo "!! /api/posts did not return data, MongoDB not reachable."; echo "   got: ${probe:0:160}"; exit 1; }
echo "   OK, server reachable and querying MongoDB."

echo "Caching sudo (somaxconn)"; sudo -v || exit 1
ORIG_SC=$(sysctl -n kern.ipc.somaxconn)
sudo sysctl -w kern.ipc.somaxconn=4096 >/dev/null
echo "somaxconn ${ORIG_SC} to 4096  (restore later: sudo sysctl -w kern.ipc.somaxconn=${ORIG_SC})"

abort(){ echo "$1"; sudo sysctl -w kern.ipc.somaxconn="${ORIG_SC}" >/dev/null; exit 1; }
reset_mern(){ mongorestore --quiet --drop --nsInclude="${MERN_DB}.*" "${MERN_DUMP}" >/dev/null 2>&1; }
post_count(){ mongosh --quiet --eval "db.getSiblingDB('${MERN_DB}').Post.countDocuments()" 2>/dev/null | tr -dc '0-9'; }
aborts_now(){ mongosh --quiet --eval "db.serverStatus().transactions.totalAborted" 2>/dev/null | tr -dc '0-9'; }

parse(){ python3 - "$1" <<'PY'
import json,sys
try:
    m=json.load(open(sys.argv[1]))["metrics"]
    fail=m["http_req_failed"]["value"]*100
    dur=m["http_req_duration"]
    p95=dur.get("p(95)", dur.get("p95", 0))
    rate=m["http_reqs"]["rate"]
    print(f"{fail:.2f} {p95:.0f} {rate:.1f}")
except Exception:
    print("ERR 0 0")
PY
}

set_mode(){
  local m="$1"
  local resp; resp=$(curl -s -X POST "${MERN_URL}/api/posts/_diag/update-mode?mode=${m}")
  echo "${resp}" | grep -q '"ok":true' || abort "!! could not set mode=${m} (got: ${resp})"
}

run_one(){
  local mode="$1" vus="$2" rep="$3"
  local out="${OUT}/mern-update-${mode}-vus${vus}-rep${rep}.json"
  reset_mern; sleep 2
  local n; n=$(post_count)
  [ "${n}" = "${EXPECT_POSTS}" ] || abort "!! after reset, Post count = ${n:-?} (expected ${EXPECT_POSTS}). Baseline/restore problem."
  local a0; a0=$(aborts_now)
  k6 run -e BASE_URL="${MERN_URL}" -e VUS="${vus}" -e OP="update" -e DURATION="${DURATION}" \
     --summary-export "${out}" "${SCRIPT}" >/dev/null 2>&1 || true
  local a1; a1=$(aborts_now)
  local fp p95 rate; read -r fp p95 rate < <(parse "${out}")
  local ab=$(( ${a1:-0} - ${a0:-0} ))
  echo "  ${mode} vus=${vus} rep=${rep}  fail=${fp}%  p95=${p95}ms  rps=${rate}  aborts=${ab}"
  echo "${mode},${vus},${rep},${fp},${p95},${rate},${ab}" >> "${CSV}"
  if [ "${fp}" != "ERR" ] && python3 -c "import sys; sys.exit(0 if float(${fp:-0})>0 else 1)"; then
    echo "    errors: $(curl -s "${MERN_URL}/api/posts/_diag/errors")"
  fi
  if [ "${fp}" != "ERR" ] && python3 -c "import sys; sys.exit(0 if float(${fp:-0})>=99 else 1)"; then
    abort "!! Run failed ${fp}%, MongoDB appears unreachable (mongod likely died). Restart mongod + MERN server, then re-run."
  fi
}

# Control: confirm the instrumented server reproduces the baseline Prisma numbers.
echo ""; echo "=== CONTROL: prisma mode (expect ~8% @1500, ~40% @3000) ==="
for vus in "${CONTROL_LEVELS[@]}"; do
  for rep in $(seq 1 ${CONTROL_REPS}); do
    set_mode prisma
    run_one prisma "${vus}" "${rep}"
  done
done

# Main: raw and raw_include interleaved per repetition.
echo ""; echo "=== MAIN: raw / raw_include interleaved ==="
for vus in "${LEVELS[@]}"; do
  for rep in $(seq 1 ${REPS}); do
    for mode in "${MODES[@]}"; do
      set_mode "${mode}"
      run_one "${mode}" "${vus}" "${rep}"
    done
  done
done

sudo sysctl -w kern.ipc.somaxconn="${ORIG_SC}" >/dev/null
echo ""; echo "MERN update sweep done. somaxconn restored to ${ORIG_SC}."
echo "Results CSV: ${CSV}"
