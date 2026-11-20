#!/usr/bin/env bash
# Controlled WAL on/off comparison for SERN, the one-variable test.
# Starts the SERN server with SQLITE_JOURNAL_MODE=DELETE (rollback journal) and
# runs the write-ish workloads at low levels, where the collapse appears fast.
# Compare against your existing WAL-on numbers at the same levels.
# Needs NO mongod. Writes to results-wal-off/ so nothing else is touched.
#
# Run:               bash benchmarks/rerun-wal-off.sh
#   control re-run:  JMODE=WAL bash benchmarks/rerun-wal-off.sh   (should match your main results)
#   more reps:       REPS=6 bash benchmarks/rerun-wal-off.sh

set -uo pipefail

export SQLITE_JOURNAL_MODE="${JMODE:-DELETE}"      # what prisma.ts will apply
SERN_URL="http://localhost:3001"
SCRIPT="benchmarks/workload.js"
OUT_DIR="benchmarks/results-wal-off"
DURATION="30s"
OPERATIONS=(create mixed)
LEVELS=(200 500 1000 1500 2000 2500 3000)
REPS="${REPS:-3}"

SERN_SERVER_DIR="sern/server"
SERN_DB="sern/server/dev.db"
SERN_SNAPSHOT="baseline/sern.db"
SERN_LOG="/tmp/sern-server.log"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || { echo "cannot cd to repo root"; exit 1; }
echo "working dir: $(pwd)   journal_mode=${SQLITE_JOURNAL_MODE}   reps=${REPS}"

command -v k6 >/dev/null || { echo "k6 not found on PATH"; exit 1; }
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
start_sern() { ( cd "${SERN_SERVER_DIR}" && exec npx tsx src/index.ts ) >"${SERN_LOG}" 2>&1 & }
wait_health() {
  local tries=0
  until curl -sf "${SERN_URL}/health" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ ${tries} -gt 60 ]; then echo "!! SERN not healthy after 60s (see ${SERN_LOG})"; return 1; fi
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

# confirm the journal mode the server actually activated (from its startup log)
reset_sern || { echo "first reset failed"; exit 1; }
echo ">> server reports: $(grep -m1 journal_mode "${SERN_LOG}" || echo '(no journal_mode line found!)')"
echo "   ^ 'active=delete' means WAL is OFF. If it says 'active=wal', the toggle did not take — stop and check."
echo ""

printf "%-7s %-6s %-4s %12s %8s %7s\n" "op" "VUs" "rep" "req/s" "p95 ms" "fail%"
echo "------------------------------------------------------------"
for op in "${OPERATIONS[@]}"; do
  for vus in "${LEVELS[@]}"; do
    for rep in $(seq 1 "${REPS}"); do
      out="${OUT_DIR}/sern-${op}-vus${vus}-rep${rep}.json"
      reset_sern || { echo "reset failed, aborting"; stop_sern; exit 1; }
      sleep 3
      k6 run -e BASE_URL="${SERN_URL}" -e VUS="${vus}" -e OP="${op}" -e DURATION="${DURATION}" \
             --summary-export "${out}" "${SCRIPT}" >/dev/null 2>&1 || true
      if [ -s "${out}" ]; then
        python3 - "${out}" "${op}" "${vus}" "${rep}" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]))["metrics"]
print("%-7s %-6s %-4s %12.0f %8.0f %7.1f" % (
    sys.argv[2], sys.argv[3], sys.argv[4],
    m["http_reqs"]["rate"], m["http_req_duration"].get("p(95)",0),
    m["http_req_failed"]["value"]*100))
PY
      else
        printf "%-7s %-6s %-4s %12s %8s %7s\n" "${op}" "${vus}" "${rep}" "-" "-" "NODATA"
      fi
    done
  done
done
stop_sern

echo ""
echo "=== mean per op/level (results-wal-off/) ==="
python3 - "${OUT_DIR}" <<'PY'
import json,glob,os,re,statistics as st
d=os.sys.argv[1]
rows={}
for f in glob.glob(os.path.join(d,"sern-*-vus*-rep*.json")):
    mo=re.search(r"sern-([a-z]+)-vus(\d+)-rep",f)
    op, vus = mo.group(1), int(mo.group(2))
    m=json.load(open(f))["metrics"]
    rows.setdefault((op,vus),[]).append((m["http_reqs"]["rate"],
        m["http_req_duration"].get("p(95)",0), m["http_req_failed"]["value"]*100))
print("%-7s %-6s %10s %9s %9s %5s" % ("op","VUs","req/s","p95 ms","fail%","reps"))
for (op,vus) in sorted(rows):
    tp=[r[0] for r in rows[(op,vus)]]; p=[r[1] for r in rows[(op,vus)]]; fl=[r[2] for r in rows[(op,vus)]]
    print("%-7s %-6d %10.0f %9.0f %8.1f %5d" % (op,vus,st.mean(tp),st.mean(p),st.mean(fl),len(fl)))
PY
echo ""
echo "WAL-ON reference you already have (create, all 0% fail):"
echo "   500:4050/s 155ms  1000:3836/s 347ms  1500:3630/s 524ms  2000:3553/s 609ms  2500:3309/s 767ms  3000:3330/s 862ms"
echo "WAL-ON reference you already have (mixed, all 0% fail):"
echo "   500:3534/s 191ms  1000:3437/s 344ms  1500:3185/s 486ms  2000:3089/s 597ms  2500:2925/s 718ms  3000:2764/s 836ms"
