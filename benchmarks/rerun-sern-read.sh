#!/usr/bin/env bash
# Reproduce ONLY the SERN read result, to check it holds.
# Reuses the exact reset/server logic and 30s ramping workload from
# run-benchmarks.sh. Writes to results-reread/ so your original results/
# are untouched. Needs NO mongod — SERN/SQLite only.
#
# Run (from anywhere):   bash benchmarks/rerun-sern-read.sh
#   faster check:        REPS=2 bash benchmarks/rerun-sern-read.sh
#   exact replication:   REPS=6 bash benchmarks/rerun-sern-read.sh

set -uo pipefail

SERN_URL="http://localhost:3001"
SCRIPT="benchmarks/workload.js"
OUT_DIR="benchmarks/results-reread"
DURATION="30s"                                  # same as the original sweep
LEVELS=(500 1000 1500 2000 2500 3000)           # same read levels
REPS="${REPS:-3}"                               # 3 is plenty to confirm; set 6 to match

SERN_SERVER_DIR="sern/server"
SERN_DB="sern/server/dev.db"
SERN_SNAPSHOT="baseline/sern.db"

# repo root, wherever invoked from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || { echo "cannot cd to repo root"; exit 1; }
echo "working dir: $(pwd)   reps=${REPS}"

command -v k6   >/dev/null || { echo "k6 not found on PATH"; exit 1; }
command -v curl >/dev/null || { echo "curl not found"; exit 1; }
[ -f "${SERN_SNAPSHOT}" ] || { echo "missing ${SERN_SNAPSHOT}"; exit 1; }
mkdir -p "${OUT_DIR}"

stop_sern() {
  local pids
  pids=$(lsof -ti tcp:3001 2>/dev/null || true)
  [ -n "${pids}" ] && kill ${pids} 2>/dev/null || true
  sleep 1
  pids=$(lsof -ti tcp:3001 2>/dev/null || true)
  [ -n "${pids}" ] && kill -9 ${pids} 2>/dev/null || true
}
start_sern() { ( cd "${SERN_SERVER_DIR}" && exec npx tsx src/index.ts ) >/tmp/sern-server.log 2>&1 & }
wait_health() {
  local tries=0
  until curl -sf "${SERN_URL}/health" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ ${tries} -gt 60 ]; then echo "!! SERN not healthy after 60s (see /tmp/sern-server.log)"; return 1; fi
    sleep 1
  done
}
reset_sern() {
  stop_sern
  rm -f "${SERN_DB}" "${SERN_DB}-wal" "${SERN_DB}-shm"
  cp "${SERN_SNAPSHOT}" "${SERN_DB}"
  start_sern
  wait_health
}

echo ""
printf "%-6s %-4s %12s %8s %7s\n" "VUs" "rep" "req/s" "p95 ms" "fail%"
echo "-------------------------------------------------"
for vus in "${LEVELS[@]}"; do
  for rep in $(seq 1 "${REPS}"); do
    out="${OUT_DIR}/sern-read-vus${vus}-rep${rep}.json"
    reset_sern || { echo "reset failed, aborting"; stop_sern; exit 1; }
    sleep 3
    k6 run -e BASE_URL="${SERN_URL}" -e VUS="${vus}" -e OP="read" -e DURATION="${DURATION}" \
           --summary-export "${out}" "${SCRIPT}" >/dev/null 2>&1 || true
    if [ -s "${out}" ]; then
      python3 - "${out}" "${vus}" "${rep}" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))["metrics"]
tput=m["http_reqs"]["rate"]
p95=m["http_req_duration"].get("p(95)",0)
fail=m["http_req_failed"]["value"]*100
print("%-6s %-4s %12.0f %8.0f %7.1f" % (sys.argv[2], sys.argv[3], tput, p95, fail))
PY
    else
      printf "%-6s %-4s %12s %8s %7s\n" "${vus}" "${rep}" "-" "-" "NO DATA"
    fi
  done
done
stop_sern

echo ""
echo "=== mean per level (results-reread/) ==="
python3 - "${OUT_DIR}" <<'PY'
import json,glob,os,re,statistics as st
d=os.sys.argv[1]
rows={}
for f in glob.glob(os.path.join(d,"sern-read-vus*-rep*.json")):
    vus=int(re.search(r"vus(\d+)",f).group(1))
    m=json.load(open(f))["metrics"]
    rows.setdefault(vus,[]).append((m["http_reqs"]["rate"], m["http_req_failed"]["value"]*100))
print("%-6s %12s %9s %6s" % ("VUs","req/s","fail%","reps"))
for vus in sorted(rows):
    tp=[r[0] for r in rows[vus]]; fl=[r[1] for r in rows[vus]]
    sd = (st.pstdev(fl) if len(fl)>1 else 0)
    print("%-6d %12.0f %8.1f±%-4.1f %4d" % (vus, st.mean(tp), st.mean(fl), sd, len(fl)))
PY
echo ""
echo "Original run for comparison:  500:0%  1000:11.5%  1500:64.3%  2000:66.4%  2500:67.5%  3000:67.4%"
