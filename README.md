# SERN vs. MERN: A Performance Comparison of SQLite and MongoDB

This repository contains the full implementation, benchmark harness, raw results,
and analysis scripts for the diploma thesis *"SERN vs. MERN: A Performance
Comparison of SQLite and MongoDB"* (BTH, 2026). It compares a **SERN** stack
(SQLite, Express, React, Node.js) against a **MERN** stack (MongoDB, Express,
React, Node.js) on throughput, latency, and reliability under increasing
concurrent load.

The work is organised as **four experiments** plus two supporting comparisons,
each mapped to a section of the thesis and to a set of scripts and result folders.

---

## 1. Project Overview

Both stacks expose an identical REST API (posts, users, comments) through the
Prisma ORM. Using a common ORM reduces the implementation differences between the
stacks so the comparison focuses on the database layer, though it does not isolate
the database engine completely. The study moves from a baseline comparison to a
diagnostic investigation of each stack's weakest operation and a remediation of each:

| Experiment | Question | Thesis section |
|---|---|---|
| 1 - Baseline | How do the stacks compare out of the box? | 5.1-5.6 |
| 2 - SERN diagnostics | Why does SERN shed reads under load? | 5.7 |
| 3 - Tuned configuration | How do both stacks perform after the TCP fix? | 5.8 |
| 4 - MERN diagnostics | Why do MERN updates fail, and can it be improved? | 5.9 |
| WAL comparison | Effect of SQLite WAL vs. rollback journal | 5.10 |
| Bulk insert | Batch-insert throughput | 5.11 |

**Summary.** SERN leads writes, updates, and the mixed workload by several times.
In the default configuration SERN shed 60-67% of reads at 1,500-3,000 VUs;
Experiment 2 traced this to the test host's TCP accept-queue limit, and raising it
(Experiment 3) removed the failures, after which SERN also leads on reads. MERN's
update workload failed up to about 40% at 3,000 VUs; Experiment 4 identified
Prisma's transactional read-modify-write update as the dominant contributing
factor, and a native single-document update removed the failures and roughly
quadrupled update throughput.

### Key Findings

| Finding (at the stated load) | Before | After |
|---|---|---|
| SERN read failures at 3,000 VUs | 67% | 0% |
| SERN create failures at 10,000 VUs | 14.5% | 0.15% |
| MERN update failures at 3,000 VUs | 40.2% | 0% |
| MERN update throughput at 3,000 VUs | 268 req/s | 1,218 req/s |
| MERN update p95 latency at 3,000 VUs | 14,870 ms | 2,563 ms |

The SERN improvements were achieved through a TCP configuration change; the MERN
improvements through an alternative update implementation. The MERN "After" figures
are the native `raw_include` implementation (compared against the Prisma default).

---

## 2. Repository Structure

```
.
|- sern/server/              SERN backend (Express + Prisma + SQLite)
|- mern/server/              MERN backend (Express + Prisma + MongoDB)
|- benchmarks/
|  |- workload.js            k6 workload (OP=create|read|update|mixed)
|  |- run-benchmarks.sh      Experiment 1: baseline sweep (default config)
|  |- diagnose-reads.sh      Experiment 2: somaxconn x backlog 2x2 factorial
|  |- diag-confirm.sh        Experiment 2: confirmation at 3,000 VUs
|  |- run-tuned.sh           Experiment 3: full sweep at tuned TCP config
|  |- mern-tuned-sweep.sh    Experiment 3: MERN-only tuned re-run
|  |- mern-update-sweep.sh   Experiment 4: Prisma vs raw vs raw_include update
|  |- rerun-wal-off.sh       WAL comparison: rollback-journal re-run
|  |- aggregate.py           Aggregates a results folder to mean +/- SD CSV
|  |- results/               Experiment 1 raw k6 output (default config)
|  |- diag-results/          Experiment 2 factorial output
|  |- diag-confirm-results/  Experiment 2 confirmation output
|  |- results-tuned/         Experiment 3 raw k6 output (tuned config)
|  |- results-mern-update/   Experiment 4 raw k6 output (three implementations)
|  |- results-wal-off/       WAL comparison output (rollback journal)
|  |- aggregated.csv         Aggregated summary used in the thesis tables
|  |- charts/                Final figures used in the thesis
```

Database files (`dev.db`, `baseline/`) and secrets (`.env`) are intentionally
**not** committed; they are regenerated from the seed scripts (Section 5).

---

## 3. Prerequisites and Software Versions

Minimum to run: Node.js 20 LTS or later, a recent k6 on the PATH, and MongoDB 7.0
(`mongod`) run as a single-node replica set `rs0` (required by Prisma for
transactions). The benchmark scripts also need **Python 3**, the **MongoDB
Database Tools** (`mongodump` / `mongorestore`), **`mongosh`**, and the
**`sqlite3`** CLI on the PATH. The TCP tuning (`kern.ipc.somaxconn` via `sysctl`)
and the `caffeinate` wrapper are **macOS-specific**; on another platform the
equivalent OS settings would be used instead.

The versions actually used for the reported experiments were:

| Software | Tested version |
|---|---|
| Node.js | 26.13.1 |
| TypeScript | 6.0.2 |
| Prisma | 6.0.0 |
| Express | 5.2.1 |
| k6 | 1.7.1 |
| MongoDB | 7.0.31 Community Edition |
| SQLite | 3.45.0 (bundled in the Prisma query engine) |

SQLite is used through Prisma, whose query engine bundles its own SQLite build
(3.45.0) independent of any system `sqlite3` CLI. Benchmarks were executed on an
Apple Silicon MacBook Pro; full hardware and OS details are in thesis Section 4.3.

---

## 4. Installation and Configuration

```bash
# install dependencies (lockfiles are committed, so npm ci is reproducible)
cd sern/server && npm ci && cd ../..
cd mern/server && npm ci && cd ../..

# configure environment (copy the template, then edit DATABASE_URL if needed)
cp sern/server/.env.example sern/server/.env
cp mern/server/.env.example mern/server/.env
```

The templates default to `file:./dev.db` (SERN, port 3001) and
`mongodb://localhost:27017/mern-thesis?replicaSet=rs0` (MERN, port 3002).

Start MongoDB as a single-node replica set (once):

```bash
mongod --replSet rs0 --dbpath <your-db-path> --port 27017 --fork --logpath <log>
mongosh --eval "rs.initiate()"   # run only the first time
```

---

## 5. Database Seeding and Reset

Both databases are seeded to a fixed baseline of **100,000 posts** (plus users and
comments). Indexes are created from the Prisma schema via `prisma db push`.

```bash
# SERN (SQLite)
cd sern/server
npx prisma db push          # creates the schema and indexes
npm run seed:large          # seeds ~100,000 posts into prisma/dev.db
cd ../..

# MERN (MongoDB, replica set must be running)
cd mern/server
npx prisma db push          # creates the indexes (authorId, postId, published)
npm run seed:large          # seeds ~100,000 posts into the mern-thesis database
cd ../..
```

The benchmark scripts restore each database to this baseline before every run, so
each run starts from the same initial state. Create the two baseline snapshots once,
after seeding (the paths below are exactly what the scripts expect):

```bash
mkdir -p baseline
cp sern/server/prisma/dev.db baseline/sern.db          # SERN reset snapshot
mongodump --db mern-thesis --out baseline/mern.dump    # MERN reset dump
```

The SERN reset in `run-benchmarks.sh` copies `baseline/sern.db` back over
`dev.db` (clearing stale `-wal`/`-shm` files); the MERN reset runs
`mongorestore --drop` from `baseline/mern.dump`. Because the seed is deterministic,
the baseline can be rebuilt on any machine from the commands above.

---

## 6. Starting the Servers

The SERN benchmark script starts and stops the SERN server itself (it has to be
down while the SQLite file is replaced). The MERN server must be started manually
before any MERN run:

```bash
# SERN (port 3001); run-benchmarks.sh also starts and stops this automatically
cd sern/server && npx tsx --env-file=.env src/index.ts

# MERN (port 3002), default backlog (Experiment 1):
cd mern/server && npx tsx --env-file=.env src/index.ts
# MERN (port 3002), tuned backlog (Experiments 3 and 4):
cd mern/server && LISTEN_BACKLOG=4096 npx tsx --env-file=.env src/index.ts
```

Verify both liveness and database connectivity. `/health` returns a static
response and does **not** query the database, so also confirm that a real query
returns data:

```bash
curl -s localhost:3001/health                          # SERN liveness
curl -s "localhost:3001/api/posts?page=1&pageSize=1"   # SERN returns data if SQLite is ready
curl -s localhost:3002/health                          # MERN liveness
curl -s "localhost:3002/api/posts?page=1&pageSize=1"   # MERN returns data if MongoDB is reachable
```

> Re-running an experiment **overwrites** the result files for the runs it repeats.
> `run-benchmarks.sh` (and `run-tuned.sh`, which calls it) honour an `OUT_DIR`
> override, for example `OUT_DIR=benchmarks/results-mine bash benchmarks/run-benchmarks.sh`.
> The diagnostic and sweep scripts write to fixed folders; copy those aside first if
> you want to preserve the published runs.

---

## 7. Experiment 1 - Baseline Performance (thesis 5.1-5.6)

Default operating-system configuration (`kern.ipc.somaxconn = 128`). Four
operations (create, read, update, mixed) at 500-3,000 VUs with **6 repetitions**,
plus a write breaking-point sweep to 10,000 VUs with **3 repetitions**.

```bash
caffeinate -i bash benchmarks/run-benchmarks.sh      # -> benchmarks/results/
python3 benchmarks/aggregate.py benchmarks/results
```

---

## 8. Experiment 2 - SERN Diagnostics (thesis 5.7)

Isolates the cause of the SERN read failures by varying the TCP accept-queue
parameters while holding the database fixed. The nominal effective backlog limit
is the smaller of `kern.ipc.somaxconn` and the application's listen backlog; the
kernel's actual queue capacity was not measured directly.

```bash
bash benchmarks/diagnose-reads.sh    # 2x2 factorial, 3 reps -> diag-results/
bash benchmarks/diag-confirm.sh      # confirmation at 3,000 VUs, 6 reps -> diag-confirm-results/
```

Finding: the read failure rate tracks the nominal effective backlog limit; raising
both parameters to 4,096 removes the failures. The summaries are written as
`summary.csv` in each output folder.

---

## 9. Experiment 3 - Tuned Configuration (thesis 5.8)

Repeats the full baseline with `kern.ipc.somaxconn` and the listen backlog both
raised to 4,096 (6 repetitions for scaling, 3 for the breaking-point sweep). Start
the MERN server with `LISTEN_BACKLOG=4096` first.

```bash
caffeinate -i bash benchmarks/run-tuned.sh           # -> benchmarks/results-tuned/
# MERN-only re-run (used after a mid-run MongoDB restart):
caffeinate -i bash benchmarks/mern-tuned-sweep.sh    # -> benchmarks/results-tuned/
python3 benchmarks/aggregate.py benchmarks/results-tuned
```

---

## 10. Experiment 4 - MERN Diagnostics (thesis 5.9)

Investigates the MERN update failures and evaluates native alternatives. The MERN
update route supports three modes via the `UPDATE_MODE` environment variable or the
`POST /api/posts/_diag/update-mode` endpoint:

- `prisma` (**default**) - Prisma read-modify-write transactional update.
- `raw` - native single-document `updateOne` (no transaction, no relation returned).
- `raw_include` - native `updateOne` plus a relation read (same response as `prisma`).

```bash
# one-shot: confirm what Prisma emits and whether it opens a transaction
cd mern/server && npx tsx --env-file=.env diag-prisma-log.ts && cd ../..

# the sweep (start the MERN server with LISTEN_BACKLOG=4096 first):
caffeinate -i bash benchmarks/mern-update-sweep.sh   # -> benchmarks/results-mern-update/runs.csv
```

The sweep runs `raw` and `raw_include` at 500-3,000 VUs with **6 repetitions**,
interleaved, plus a short `prisma` control; the full-protocol Prisma column is
**reused from Experiment 3** (same tuned configuration and dataset). The server's
default behaviour is unchanged (`prisma`); the native modes are only ever activated
explicitly for this experiment. Finding: the Prisma update failures are MongoDB
transaction write conflicts (error P2034), and both native modes run failure-free.
The native implementations are not fully semantically equivalent to the Prisma
update: they forgo Prisma's type-safe query building, and **neither** `raw` nor
`raw_include` runs inside the multi-document transaction, so both lack its atomic
guarantees (`raw` additionally returns no relation data). The comparison therefore
isolates Prisma's transactional read-modify-write implementation as a whole rather
than the transaction primitive alone.

---

## 11. Additional Experiments: WAL and Bulk Insert (thesis 5.10-5.11)

```bash
# WAL vs rollback journal: results/ holds the WAL-on data (Experiment 1);
# this re-runs SQLite in rollback-journal mode:
bash benchmarks/rerun-wal-off.sh                     # -> benchmarks/results-wal-off/
```

The bulk-insert comparison (thesis 5.11) uses the `POST /api/posts/batch` endpoint,
which inserts an array of posts in one request. With a server running and valid
author ids from the seeded data, a single batch call looks like:

```bash
curl -X POST localhost:3001/api/posts/batch \
  -H "Content-Type: application/json" \
  -d '{"posts":[{"title":"t","content":"c","published":false,"authorId":"<id>"}]}'
```

---

## 12. Results and Visualizations

- Raw per-run k6 output is under each `results*/` folder (one JSON per
  operation x VU level x repetition).
- `python3 aggregate.py <folder>` produces the mean +/- SD summary and writes
  `aggregated.csv`; `aggregated.csv` in the repo root of `benchmarks/` is the
  combined summary used in the thesis tables.
- `charts/` holds the final figures used in the thesis.

---

## 13. Reproducibility and Limitations

- Each run resets the database to the 100,000-post baseline, so every run starts
  from the same initial state; six repetitions per level support the reported
  standard deviations.
- Results are specific to the tested software versions, the single-server
  deployment, the Prisma ORM, and Apple Silicon hardware; they do not establish
  distributed-deployment behaviour.
- The read and update workloads target the 500 most-recently-created posts (the
  first page of the seeded set), which concentrates contention; this is a property
  of the workload and is discussed in thesis Sections 4.8 and 5.9.
- Diagnostic results that did not match the expected outcome are retained as part
  of the scientific record. Superseded exploratory runs are archived outside this
  repository.
- After cloning, confirm the setup in two steps. First, a quick application check
  that does not depend on the benchmark reset: seed a small dataset
  (`npm run seed`), start a server, and confirm `curl "localhost:3001/api/posts?page=1&pageSize=1"`
  returns data. Second, a pipeline check with the full baseline in place (run
  `seed:large` and create the baseline snapshots from Section 5, since the scripts
  reset from those snapshots and the workload reads the first 500 posts):
  `SMOKE=1 bash benchmarks/run-benchmarks.sh` (all operations, one rep at 500 VU,
  no breaking sweep). Note that `mern-update-sweep.sh` verifies a 100,000-post
  count after each reset, so it requires the full `seed:large` baseline.
```
