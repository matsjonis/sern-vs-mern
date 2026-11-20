import { PrismaClient } from "@prisma/client";

const prisma = new PrismaClient({});

// Journal mode is configurable so we can benchmark WAL vs rollback-journal.
// Defaults to WAL (the production config). Set SQLITE_JOURNAL_MODE=DELETE to test without WAL.
//
// NOTE: WAL is PERSISTENT in the SQLite file header — an existing WAL file stays in
// WAL mode across restarts. So we must set the mode explicitly on every startup;
// simply removing this line would leave the baseline file in WAL mode.
const requested = (process.env.SQLITE_JOURNAL_MODE ?? "WAL").toUpperCase();
const allowed = ["WAL", "DELETE", "TRUNCATE", "PERSIST", "MEMORY", "OFF"];
const journalMode = allowed.includes(requested) ? requested : "WAL";

const result = (await prisma.$queryRawUnsafe(
  `PRAGMA journal_mode = ${journalMode};`
)) as Array<{ journal_mode: string }>;

console.log(`[SERN] SQLite journal_mode requested=${journalMode} active=${result[0]?.journal_mode}`);

export default prisma;
