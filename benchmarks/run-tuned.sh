#!/usr/bin/env bash
# Experiment 3: full SERN + MERN sweep under a tuned, shared TCP config
# (kern.ipc.somaxconn = 4096, Node listen backlog = 4096). Writes to results-tuned/.
# Run: caffeinate -i bash benchmarks/run-tuned.sh   (see README for prereqs)
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.." || { echo "cannot cd to repo root"; exit 1; }

echo "Caching sudo (to set kern.ipc.somaxconn)"
sudo -v || { echo "sudo required"; exit 1; }
ORIG_SC=$(sysctl -n kern.ipc.somaxconn)
sudo sysctl -w kern.ipc.somaxconn=4096 >/dev/null
echo "somaxconn ${ORIG_SC} to 4096"

if ! curl -sf http://localhost:3002/health >/dev/null 2>&1; then
  echo "!! MERN server not reachable on :3002."
  echo "   Start the MERN server first:  cd mern/server && LISTEN_BACKLOG=4096 npx tsx --env-file=.env src/index.ts"
  sudo sysctl -w kern.ipc.somaxconn="${ORIG_SC}" >/dev/null
  exit 1
fi

echo ">>> Full sweep to benchmarks/results-tuned/ (SERN backlog via LISTEN_BACKLOG=4096) <<<"
OUT_DIR="benchmarks/results-tuned" LISTEN_BACKLOG=4096 bash benchmarks/run-benchmarks.sh

echo ""
echo "Tuned sweep complete."
echo "  Aggregate:  cd benchmarks && python3 aggregate.py results-tuned"
echo "  Restore the default somaxconn with:  sudo sysctl -w kern.ipc.somaxconn=${ORIG_SC}"
