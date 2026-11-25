#!/usr/bin/env bash
# Experiment 2: diagnostic for the SERN read failures. 2x2 factorial over
# kern.ipc.somaxconn x Node listen backlog at 1500 VU reads, plus a reversal run.
# Run: bash benchmarks/diagnose-reads.sh   (SERN only; see README for prereqs)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || { echo "cannot cd to repo root"; exit 1; }
echo "working dir: $(pwd)"

URL="http://localhost:3001"
SCRIPT="benchmarks/workload.js"
SERN_SERVER_DIR="sern/server"
SERN_DB="sern/server/prisma/dev.db"
SERN_SNAPSHOT="baseline/sern.db"
VUS=1500
DURATION="30s"
REPS=3
OUT="benchmarks/diag-results"
mkdir -p "${OUT}"

command -v k6 >/dev/null || { echo "k6 not found on PATH"; exit 1; }
[ -f "${SERN_SNAPSHOT}" ] || { echo "baseline/sern.db missing, run the setup/seed step first"; exit 1; }

echo "Caching sudo (needed to change kern.ipc.somaxconn)"
sudo -v || { echo "sudo required for sysctl"; exit 1; }
ORIG_SC=$(sysctl -n kern.ipc.somaxconn)
echo "original kern.ipc.somaxconn = ${ORIG_SC}"

CUR_SC=""
set_somaxconn() { local v="$1"; if [ "${CUR_SC}" != "${v}" ]; then sudo sysctl -w kern.ipc.somaxconn="${v}" >/dev/null; CUR_SC="${v}"; fi; }

stop_sern() {
  local pids; pids=$(lsof -ti tcp:3001 2>/dev/null || true)
  [ -n "${pids}" ] && kill ${pids} 2>/dev/null || true
  sleep 1
  pids=$(lsof -ti tcp:3001 2>/dev/null || true)
  [ -n "${pids}" ] && kill -9 ${pids} 2>/dev/null || true
}
start_sern() { ( cd "${SERN_SERVER_DIR}" && LISTEN_BACKLOG="$1" exec npx tsx --env-file=.env src/index.ts ) >/tmp/sern-diag.log 2>&1 & }
wait_health() { local t=0; until curl -sf "${URL}/health" >/dev/null 2>&1; do t=$((t+1)); [ ${t} -gt 60 ] && { echo "!! not healthy (see /tmp/sern-diag.log)"; return 1; }; sleep 1; done; }
reset_and_start() {
  stop_sern
  rm -f "${SERN_DB}" "${SERN_DB}-wal" "${SERN_DB}-shm"
  cp "${SERN_SNAPSHOT}" "${SERN_DB}"
  start_sern "$1"; wait_health || exit 1
}

metrics_from() {
  python3 - "$1" <<'PY'
import json,sys
try:
    m=json.load(open(sys.argv[1]))["metrics"]
    print(f'{m.get("http_req_failed",{}).get("value",0.0)*100:.2f} {m.get("http_reqs",{}).get("rate",0.0):.0f}')
except Exception:
    print("0 0")
PY
}
netdiff() {
  python3 - "$1" "$2" <<'PY'
import re,sys
def load(p):
    d={}
    for ln in open(p):
        m=re.match(r'\s*(\d+)\s+(.*\S)\s*$', ln)
        if m: d[m.group(2)]=int(m.group(1))
    return d
a,b=load(sys.argv[1]),load(sys.argv[2])
rows=[(b[k]-a.get(k,0),k) for k in b
      if b[k]-a.get(k,0)>0 and re.search(r'(overflow|listen queue|drop|reset|rst|accept|connection request|established)',k,re.I)]
for delta,k in sorted(rows,reverse=True): print(f"      +{delta}  {k}")
PY
}

echo "config,somaxconn,backlog,fail_pct_mean,reqs_mean,evloop_max_ms" > "${OUT}/summary.csv"

run_config() {
  local name="$1" sc="$2" bl="$3"
  echo ""; echo "=== ${name}: somaxconn=${sc}  backlog=${bl}  (effective accept queue = min of the two) ==="
  set_somaxconn "${sc}"
  reset_and_start "${bl}"
  curl -s "${URL}/diag/eventloop?reset=1" >/dev/null
  netstat -s -p tcp > "${OUT}/${name}-before.txt"
  local fsum=0 rsum=0 f=0 r=0
  for rep in $(seq 1 "${REPS}"); do
    local out="${OUT}/${name}-read-vus${VUS}-rep${rep}.json"
    k6 run -e BASE_URL="${URL}" -e VUS="${VUS}" -e OP="read" -e DURATION="${DURATION}" \
       --summary-export "${out}" "${SCRIPT}" >/dev/null 2>&1 || true
    f=0; r=0; read f r < <(metrics_from "${out}") || true
    echo "   rep${rep}: fail=${f}%  req/s=${r}"
    fsum=$(python3 -c "print(${fsum}+${f})"); rsum=$(python3 -c "print(${rsum}+${r})")
  done
  netstat -s -p tcp > "${OUT}/${name}-after.txt"
  local eld; eld=$(curl -s "${URL}/diag/eventloop")
  stop_sern
  local fmean rmean elmax
  fmean=$(python3 -c "print(f'{${fsum}/${REPS}:.1f}')")
  rmean=$(python3 -c "print(f'{${rsum}/${REPS}:.0f}')")
  elmax=$(python3 -c "import json,sys;print(json.loads('''${eld}''').get('max_ms','?'))" 2>/dev/null || echo "?")
  echo "   MEAN: fail=${fmean}%  req/s=${rmean}   event loop max=${elmax} ms"
  echo "   TCP counter deltas over the test window:"
  netdiff "${OUT}/${name}-before.txt" "${OUT}/${name}-after.txt"
  echo "${name},${sc},${bl},${fmean},${rmean},${elmax}" >> "${OUT}/summary.csv"
}

run_config "A_baseline"  128  511
run_config "B_backlog"   128  4096
run_config "C_somaxconn" 4096 511
run_config "D_both"      4096 4096
run_config "A_reversal"  128  511     # causality check

sudo sysctl -w kern.ipc.somaxconn="${ORIG_SC}" >/dev/null
echo ""; echo "kern.ipc.somaxconn restored to ${ORIG_SC}"
echo ""; echo "=== SUMMARY (${OUT}/summary.csv) ==="
column -t -s, "${OUT}/summary.csv"
