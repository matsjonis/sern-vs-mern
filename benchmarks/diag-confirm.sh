#!/usr/bin/env bash
# Experiment 2: confirmation runs for the SERN read-failure diagnostic, 6 reps each at 3000 VU.
#   SERN somaxconn 128 (baseline), SERN somaxconn+backlog 4096 (fix), MERN somaxconn 4096 (fairness).
# Run: bash benchmarks/diag-confirm.sh   (start the MERN server for the fairness step; see README)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || { echo "cannot cd to repo root"; exit 1; }
echo "working dir: $(pwd)"

SERN_URL="http://localhost:3001"
MERN_URL="http://localhost:3002"
SCRIPT="benchmarks/workload.js"
SERN_SERVER_DIR="sern/server"
SERN_DB="sern/server/prisma/dev.db"
SERN_SNAPSHOT="baseline/sern.db"
MERN_DB="mern-thesis"
MERN_DUMP="baseline/mern.dump"
VUS=3000
DURATION="30s"
REPS=6
OUT="benchmarks/diag-confirm-results"
mkdir -p "${OUT}"

command -v k6 >/dev/null || { echo "k6 not found"; exit 1; }
[ -f "${SERN_SNAPSHOT}" ] || { echo "baseline/sern.db missing"; exit 1; }

echo "Caching sudo (needed for kern.ipc.somaxconn)"; sudo -v || { echo "sudo required"; exit 1; }
ORIG_SC=$(sysctl -n kern.ipc.somaxconn); echo "original somaxconn = ${ORIG_SC}"
CUR_SC=""
set_sc() { local v="$1"; if [ "${CUR_SC}" != "${v}" ]; then sudo sysctl -w kern.ipc.somaxconn="${v}" >/dev/null; CUR_SC="${v}"; fi; }

stop_sern() { local p; p=$(lsof -ti tcp:3001 2>/dev/null||true); [ -n "${p}" ]&&kill ${p} 2>/dev/null||true; sleep 1; p=$(lsof -ti tcp:3001 2>/dev/null||true); [ -n "${p}" ]&&kill -9 ${p} 2>/dev/null||true; }
start_sern() { ( cd "${SERN_SERVER_DIR}" && LISTEN_BACKLOG="$1" exec npx tsx --env-file=.env src/index.ts ) >/tmp/sern-confirm.log 2>&1 & }
wait_health() { local u="$1" t=0; until curl -sf "${u}/health" >/dev/null 2>&1; do t=$((t+1)); [ ${t} -gt 60 ]&&{ echo "!! ${u} not healthy"; return 1; }; sleep 1; done; }
reset_sern_start() { stop_sern; rm -f "${SERN_DB}" "${SERN_DB}-wal" "${SERN_DB}-shm"; cp "${SERN_SNAPSHOT}" "${SERN_DB}"; start_sern "$1"; wait_health "${SERN_URL}"||exit 1; }
reset_mern() { mongorestore --quiet --drop --nsInclude="${MERN_DB}.*" "${MERN_DUMP}" >/dev/null 2>&1; }

metrics_from() { python3 - "$1" <<'PY'
import json,sys
try:
    m=json.load(open(sys.argv[1]))["metrics"]
    print(f'{m.get("http_req_failed",{}).get("value",0.0)*100:.2f} {m.get("http_reqs",{}).get("rate",0.0):.0f}')
except Exception: print("0 0")
PY
}

echo "config,stack,somaxconn,backlog,vus,fail_pct_mean,reqs_mean" > "${OUT}/summary.csv"

run_sern() {
  local name="$1" sc="$2" bl="$3"
  echo ""; echo "=== ${name}: SERN  somaxconn=${sc} backlog=${bl}  @${VUS} VU x${REPS} ==="
  set_sc "${sc}"; reset_sern_start "${bl}"
  local klog="${OUT}/${name}.k6log"; : > "${klog}"
  local fsum=0 rsum=0 f r
  for rep in $(seq 1 "${REPS}"); do
    local out="${OUT}/${name}-rep${rep}.json"
    k6 run -e BASE_URL="${SERN_URL}" -e VUS="${VUS}" -e OP="read" -e DURATION="${DURATION}" \
       --summary-export "${out}" "${SCRIPT}" >>"${klog}" 2>&1 || true
    f=0; r=0; read f r < <(metrics_from "${out}") || true
    echo "   rep${rep}: fail=${f}%  req/s=${r}"
    fsum=$(python3 -c "print(${fsum}+${f})"); rsum=$(python3 -c "print(${rsum}+${r})")
  done
  stop_sern
  local fm rm; fm=$(python3 -c "print(f'{${fsum}/${REPS}:.1f}')"); rm=$(python3 -c "print(f'{${rsum}/${REPS}:.0f}')")
  echo "   MEAN: fail=${fm}%  req/s=${rm}"
  echo "   k6 error types seen:"
  grep -oE 'error="[^"]*"' "${klog}" | sed -E 's/[0-9]+/N/g' | sort | uniq -c | sort -rn | head -6 | sed 's/^/      /'
  [ -s "${klog}" ] && ! grep -q 'error=' "${klog}" && echo "      (none)"
  echo "${name},sern,${sc},${bl},${VUS},${fm},${rm}" >> "${OUT}/summary.csv"
}

run_sern "SERN_sc128_baseline" 128  511
run_sern "SERN_sc4096_fixed"   4096 4096

# MERN fairness (needs the MERN server on :3002)
echo ""; echo "=== MERN fairness: somaxconn=4096 @${VUS} VU x${REPS} ==="
set_sc 4096
if curl -sf "${MERN_URL}/health" >/dev/null 2>&1; then
  local_ok=1
  fsum=0; rsum=0
  for rep in $(seq 1 "${REPS}"); do
    reset_mern
    out="${OUT}/MERN_sc4096-rep${rep}.json"
    k6 run -e BASE_URL="${MERN_URL}" -e VUS="${VUS}" -e OP="read" -e DURATION="${DURATION}" \
       --summary-export "${out}" "${SCRIPT}" >/dev/null 2>&1 || true
    f=0; r=0; read f r < <(metrics_from "${out}") || true
    echo "   rep${rep}: fail=${f}%  req/s=${r}"
    fsum=$(python3 -c "print(${fsum}+${f})"); rsum=$(python3 -c "print(${rsum}+${r})")
  done
  fm=$(python3 -c "print(f'{${fsum}/${REPS}:.1f}')"); rm=$(python3 -c "print(f'{${rsum}/${REPS}:.0f}')")
  echo "   MEAN: fail=${fm}%  req/s=${rm}"
  echo "MERN_sc4096,mern,4096,default,${VUS},${fm},${rm}" >> "${OUT}/summary.csv"
else
  echo "   MERN server not reachable on :3002, skipped. Start it (and mongod) and re-run to add the fairness point."
fi

sudo sysctl -w kern.ipc.somaxconn="${ORIG_SC}" >/dev/null
echo ""; echo "somaxconn restored to ${ORIG_SC}"
echo ""; echo "=== SUMMARY ==="; column -t -s, "${OUT}/summary.csv"
