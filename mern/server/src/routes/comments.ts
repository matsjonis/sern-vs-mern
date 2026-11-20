import { Router, type Request, type Response } from "express";
import prisma from "../prisma.js";

export const commentRouter = Router();

// GET /api/comments?postId=xxx
commentRouter.get("/", async (req: Request, res: Response) => {
  try {
    const postId = req.query.postId as string | undefined;
    const where: any = {};
    if (postId) where.postId = postId;

    const comments = await prisma.comment.findMany({
      where,
      include: {
        author: { select: { id: true, name: true } },
        post: { select: { id: true, title: true } },
      },
      orderBy: { createdAt: "desc" },
    });
    res.json({ success: true, data: comments });
  } catch (error) {
    res.status(500).json({ success: false, error: "Failed to fetch comments" });
  }
});

// POST /api/comments
commentRouter.post("/", async (req: Request, res: Response) => {
  try {
    const { content, postId, authorId } = req.body;
    const comment = await prisma.comment.create({
      data: { content, postId, authorId },
      include: {
        author: { select: { id: true, name: true } },
      },
    });
    res.status(201).json({ success: true, data: comment });
  } catch (error) {
    res.status(400).json({ success: false, error: "Failed to create comment" });
  }
});

// POST /api/comments/batch — for benchmarking
commentRouter.post("/batch", async (req: Request, res: Response) => {
  try {
    const { comments } = req.body;
    const count = await prisma.comment.createMany({ data: comments });
    res.status(201).json({ success: true, data: { count: count.count } });
  } catch (error) {
    res.status(400).json({ success: false, error: "Failed to batch create comments" });
  }
});

// PUT /api/comments/:id
commentRouter.put("/:id", async (req: Request, res: Response) => {
  try {
    const { content } = req.body;
    const comment = await prisma.comment.update({
      where: { id: req.params.id as string },
      data: { content },
      include: {
        author: { select: { id: true, name: true } },
      },
    });
    res.json({ success: true, data: comment });
  } catch (error) {
    res.status(400).json({ success: false, error: "Failed to update comment" });
  }
});

// DELETE /api/comments/:id
commentRouter.delete("/:id", async (req: Request, res: Response) => {
  try {
    await prisma.comment.delete({
      where: { id: req.params.id as string },
    });
    res.json({ success: true, data: null });
  } catch (error) {
    res.status(400).json({ success: false, error: "Failed to delete comment" });
  }
});
