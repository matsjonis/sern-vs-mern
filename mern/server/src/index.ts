import express from "express";
import cors from "cors";
import { monitorEventLoopDelay } from "perf_hooks";
import { userRouter } from "./routes/users.js";
import { postRouter } from "./routes/posts.js";
import { commentRouter } from "./routes/comments.js";

const PORT = Number(process.env.PORT || 3002);

const app = express();
app.use(cors());
app.use(express.json());

// Event loop delay instrumentation for the diagnostics.
const eld = monitorEventLoopDelay({ resolution: 20 });
eld.enable();
const toMs = (ns: number) => Math.round((ns / 1e6) * 100) / 100;

app.get("/health", (_req, res) => {
  res.json({ status: "ok", stack: "MERN", database: "MongoDB" });
});

app.get("/diag/eventloop", (req, res) => {
  res.json({
    mean_ms: toMs(eld.mean),
    max_ms: toMs(eld.max),
    p99_ms: toMs(eld.percentile(99)),
    stddev_ms: toMs(eld.stddev),
  });
  if (req.query.reset === "1") eld.reset();
});

app.use("/api/users", userRouter);
app.use("/api/posts", postRouter);
app.use("/api/comments", commentRouter);

// Listen backlog configurable via LISTEN_BACKLOG (default 511). The OS caps the accept queue at kern.ipc.somaxconn.
const BACKLOG = parseInt(process.env.LISTEN_BACKLOG || "511", 10);
app.listen({ port: PORT, backlog: BACKLOG }, () => {
  console.log(`[MERN] http://localhost:${PORT} (backlog=${BACKLOG})`);
});
