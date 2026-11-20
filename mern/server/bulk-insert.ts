/**
 * Bulk-insert benchmark — measures batch createMany() throughput (rows/sec).
 * Run once per stack. Place this file in the stack's server dir so that
 * `@prisma/client` resolves to THAT stack's generated client:
 *
 *   cp bulk-insert.ts sern/server/ && (cd sern/server && npx tsx bulk-insert.ts)
 *   cp bulk-insert.ts mern/server/ && (cd mern/server && npx tsx bulk-insert.ts)
 *
 * Config via env:   BATCH_SIZES=1000,10000,100000   REPS=5   CONTENT_CHARS=300
 *
 * NOTE: this clears the posts table (and comments via cascade) to measure clean
 * inserts, so it wipes the 100k baseline data. Restore afterwards if needed:
 *   SERN:  cp baseline/sern.db sern/server/dev.db
 *   MERN:  mongorestore --drop --nsInclude="mern-thesis.*" baseline/mern.dump
 */
import { readFileSync, existsSync } from "node:fs";
import { performance } from "node:perf_hooks";

// Minimal .env loader (no dotenv dependency): load DATABASE_URL etc. from the
// nearest .env if not already set in the shell environment. Must run BEFORE
// PrismaClient is constructed.
for (const path of [".env", "../.env", "../../.env"]) {
  if (!existsSync(path)) continue;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s*([\w.-]+)\s*=\s*(.*?)\s*$/);
    if (m && !(m[1] in process.env)) {
      let v = m[2];
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
      process.env[m[1]] = v;
    }
  }
  break;
}

const { PrismaClient } = await import("@prisma/client");
const prisma = new PrismaClient();

const BATCH_SIZES = (process.env.BATCH_SIZES ?? "1000,10000,100000")
  .split(",").map((s) => Number(s.trim())).filter((n) => n > 0);
const REPS = Number(process.env.REPS ?? 5);
const CONTENT = "x".repeat(Number(process.env.CONTENT_CHARS ?? 300));

async function ensureUsers(): Promise<string[]> {
  const existing = await prisma.user.findMany({ take: 10, select: { id: true } });
  if (existing.length > 0) return existing.map((u: { id: string }) => u.id);
  const ids: string[] = [];
  for (let i = 0; i < 10; i++) {
    const u = await prisma.user.create({
      data: { email: `bulk${i}@test.local`, name: `Bulk User ${i}` },
    });
    ids.push(u.id);
  }
  return ids;
}

function makePosts(n: number, userIds: string[]) {
  const data = new Array(n);
  for (let i = 0; i < n; i++) {
    data[i] = { title: `Post ${i}`, content: CONTENT, authorId: userIds[i % userIds.length] };
  }
  return data;
}

async function main() {
  if (!process.env.DATABASE_URL) {
    console.error("DATABASE_URL is not set and no .env was found next to this script.");
    process.exit(1);
  }
  const userIds = await ensureUsers();
  console.log(`batch,rep,seconds,rows_per_sec`);
  const results: Record<number, number[]> = {};

  for (const batch of BATCH_SIZES) {
    results[batch] = [];
    for (let rep = 1; rep <= REPS; rep++) {
      await prisma.post.deleteMany({});          // clear (untimed)
      const data = makePosts(batch, userIds);    // build data (untimed)
      const t0 = performance.now();
      await prisma.post.createMany({ data });
      const secs = (performance.now() - t0) / 1000;
      const rps = batch / secs;
      results[batch].push(rps);
      console.log(`${batch},${rep},${secs.toFixed(3)},${Math.round(rps)}`);
    }
  }

  console.log(`\n=== mean rows/sec per batch ===`);
  for (const batch of BATCH_SIZES) {
    const a = results[batch];
    const mean = a.reduce((x, y) => x + y, 0) / a.length;
    const sd = Math.sqrt(a.reduce((x, y) => x + (y - mean) ** 2, 0) / a.length);
    console.log(`batch=${batch}: ${Math.round(mean)} rows/sec  (±${Math.round(sd)}, n=${a.length})`);
  }
  await prisma.post.deleteMany({});
  await prisma.$disconnect();
}

main().catch(async (e) => { console.error(e); await prisma.$disconnect(); process.exit(1); });
