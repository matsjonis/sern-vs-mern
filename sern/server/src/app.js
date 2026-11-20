import express from "express";
import cors from "cors";
import { userRouter } from "./routes/users.js";
import { postRouter } from "./routes/posts.js";
import { commentRouter } from "./routes/comments.js";

const app = express();

app.use(cors());
app.use(express.json());

// Health check
app.get("/health", (_req, res) => {
  res.json({ status: "ok", stack: "SERN", database: "SQLite" });
});

// Routes
app.use("/api/users", userRouter);
app.use("/api/posts", postRouter);
app.use("/api/comments", commentRouter);

export default app;