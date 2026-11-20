import { Router, type Request, type Response } from "express";
import prisma from "../prisma.js";

export const userRouter = Router();

// GET /api/users
userRouter.get("/", async (_req: Request, res: Response) => {
  try {
    const users = await prisma.user.findMany({
      orderBy: { createdAt: "desc" },
    });
    res.json({ success: true, data: users });
  } catch (error) {
    res.status(500).json({ success: false, error: "Failed to fetch users" });
  }
});

// GET /api/users/:id
userRouter.get("/:id", async (req: Request, res: Response) => {
  try {
    const user = await prisma.user.findUnique({
      where: { id: req.params.id as string },
      include: {
        posts: { orderBy: { createdAt: "desc" } },
        _count: { select: { posts: true, comments: true } },
      },
    });

    if (!user) {
      res.status(404).json({ success: false, error: "User not found" });
      return;
    }

    res.json({ success: true, data: user });
  } catch (error) {
    res.status(500).json({ success: false, error: "Failed to fetch user" });
  }
});

// POST /api/users
userRouter.post("/", async (req: Request, res: Response) => {
  try {
    const { email, name } = req.body;
    const user = await prisma.user.create({
      data: { email, name },
    });
    res.status(201).json({ success: true, data: user });
  } catch (error) {
    res.status(400).json({ success: false, error: "Failed to create user" });
  }
});

// PUT /api/users/:id
userRouter.put("/:id", async (req: Request, res: Response) => {
  try {
    const { email, name } = req.body;
    const user = await prisma.user.update({
      where: { id: req.params.id as string },
      data: { email, name },
    });
    res.json({ success: true, data: user });
  } catch (error) {
    res.status(400).json({ success: false, error: "Failed to update user" });
  }
});

// DELETE /api/users/:id
userRouter.delete("/:id", async (req: Request, res: Response) => {
  try {
    await prisma.user.delete({
      where: { id: req.params.id as string },
    });
    res.json({ success: true, data: null });
  } catch (error) {
    res.status(400).json({ success: false, error: "Failed to delete user" });
  }
});