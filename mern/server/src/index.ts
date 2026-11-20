import express from "express";
import cors from "cors";
import { userRouter } from "./routes/users.js";
import { postRouter } from "./routes/posts.js";
import { commentRouter } from "./routes/comments.js";
const PORT = process.env.PORT || 3002;


const app = express();
app.use(cors());
app.use(express.json());

app.get("/health", (_req, res) => {
  res.json({ status: "ok", stack: "MERN", database: "MongoDB" });
});

app.use("/api/users", userRouter);
app.use("/api/posts", postRouter);
app.use("/api/comments", commentRouter);


app.listen(PORT, () => {
  console.log(`[MERN] http://localhost:${PORT}`);
});
