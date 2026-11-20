import express from "express";
import cors from "cors";
import { userRouter } from "./routes/users.js";
import { postRouter } from "./routes/posts.js";
import { commentRouter } from "./routes/comments.js";

const app = express();
app.use(cors());
app.use(express.json());

app.get("/health", (_req, res) => {
  res.json({ status: "ok", stack: "SERN", database: "SQLite" });
});

app.use("/api/users", userRouter);
app.use("/api/posts", postRouter);
app.use("/api/comments", commentRouter);

app.listen(3001, () => {
  console.log("[SERN] http://localhost:3001");
});