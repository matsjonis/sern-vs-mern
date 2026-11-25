import { Router, type Request, type Response } from "express";
import prisma from "../prisma.js";

export const postRouter = Router();

// Diagnostic counters for the MERN update investigation (Experiment 4).
export let updateErrors: Record<string, number> = {};
export let updateErrorSamples: string[] = [];

// Update mode for Experiment 4: prisma (default), raw, or raw_include.
let updateMode = (process.env.UPDATE_MODE || "prisma").toLowerCase();
const VALID_MODES = ["prisma", "raw", "raw_include"];

// Registered before the id route so it is not matched as an id.
postRouter.get("/_diag/errors", (_req: Request, res: Response) => {
  res.json({ mode: updateMode, counts: updateErrors, samples: updateErrorSamples });
});

// Switch update mode and reset the counters.
postRouter.post("/_diag/update-mode", (req: Request, res: Response) => {
  const m = String(req.query.mode || "").toLowerCase();
  if (!VALID_MODES.includes(m)) {
    res.status(400).json({ ok: false, error: `mode must be one of ${VALID_MODES.join("|")}` });
    return;
  }
  updateMode = m;
  updateErrors = {};
  updateErrorSamples = [];
  res.json({ ok: true, mode: updateMode });
});

// GET /api/posts
postRouter.get("/", async (req: Request, res: Response) => {
  try {
    const page = parseInt(req.query.page as string) || 1;
    const pageSize = parseInt(req.query.pageSize as string) || 10;
    const published = req.query.published === "true" ? true : req.query.published === "false" ? false : undefined;
    const authorId = req.query.authorId as string | undefined;
    const search = req.query.search as string | undefined;

    const where: any = {};
    if (published !== undefined) where.published = published;
    if (authorId) where.authorId = authorId;
    if (search) {
      where.OR = [
        { title: { contains: search } },
        { content: { contains: search } },
      ];
    }

    const [posts, total] = await Promise.all([
      prisma.post.findMany({
        where,
        include: {
          author: { select: { id: true, name: true, email: true } },
          _count: { select: { comments: true } },
        },
        orderBy: { createdAt: "desc" },
        skip: (page - 1) * pageSize,
        take: pageSize,
      }),
      prisma.post.count({ where }),
    ]);

    res.json({
      success: true,
      data: posts,
      meta: { total, page, pageSize },
    });
  } catch (error) {
    res.status(500).json({ success: false, error: "Failed to fetch posts" });
  }
});

// GET /api/posts/:id
postRouter.get("/:id", async (req: Request, res: Response) => {
  try {
    const post = await prisma.post.findUnique({
      where: { id: req.params.id as string },
      include: {
        author: { select: { id: true, name: true, email: true } },
        comments: {
          include: {
            author: { select: { id: true, name: true } },
          },
          orderBy: { createdAt: "desc" },
        },
      },
    });

    if (!post) {
      res.status(404).json({ success: false, error: "Post not found" });
      return;
    }

    res.json({ success: true, data: post });
  } catch (error) {
    res.status(500).json({ success: false, error: "Failed to fetch post" });
  }
});

// POST /api/posts
postRouter.post("/", async (req: Request, res: Response) => {
  try {
    const { title, content, published, authorId } = req.body;
    const post = await prisma.post.create({
      data: { title, content, published: published ?? false, authorId },
      include: {
        author: { select: { id: true, name: true, email: true } },
      },
    });
    res.status(201).json({ success: true, data: post });
  } catch (error) {
    res.status(400).json({ success: false, error: "Failed to create post" });
  }
});

// POST /api/posts/batch
postRouter.post("/batch", async (req: Request, res: Response) => {
  try {
    const { posts } = req.body;
    const count = await prisma.post.createMany({ data: posts });
    res.status(201).json({ success: true, data: { count: count.count } });
  } catch (error) {
    res.status(400).json({ success: false, error: "Failed to batch create posts" });
  }
});

// Native updateOne. No transaction.
async function rawUpdateOne(id: string, title: unknown, content: unknown, published: unknown) {
  const set: Record<string, unknown> = { updatedAt: { $date: new Date().toISOString() } };
  if (title !== undefined) set.title = title;
  if (content !== undefined) set.content = content;
  if (published !== undefined) set.published = published;

  // $runCommandRaw takes a dynamic BSON command; the cast is required.
  const command: any = {
    update: "Post",
    updates: [
      { q: { _id: { $oid: id } }, u: { $set: set }, multi: false },
    ],
  };
  return prisma.$runCommandRaw(command);
}

// PUT /api/posts/:id
postRouter.put("/:id", async (req: Request, res: Response) => {
  try {
    const { title, content, published } = req.body;
    const id = req.params.id as string;

    if (updateMode === "raw") {
      const result = await rawUpdateOne(id, title, content, published);
      res.json({ success: true, data: result });
    } else if (updateMode === "raw_include") {
      await rawUpdateOne(id, title, content, published);
      const post = await prisma.post.findUnique({
        where: { id },
        include: { author: { select: { id: true, name: true, email: true } } },
      });
      res.json({ success: true, data: post });
    } else {
      const post = await prisma.post.update({
        where: { id },
        data: { title, content, published },
        include: {
          author: { select: { id: true, name: true, email: true } },
        },
      });
      res.json({ success: true, data: post });
    }
  } catch (error: any) {
    const key = error?.code || error?.name || "unknown";
    updateErrors[key] = (updateErrors[key] || 0) + 1;
    if (updateErrorSamples.length < 5) {
      updateErrorSamples.push(String(error?.message || error).slice(0, 300));
    }
    res.status(400).json({ success: false, error: "Failed to update post" });
  }
});

// DELETE /api/posts/:id
postRouter.delete("/:id", async (req: Request, res: Response) => {
  try {
    await prisma.post.delete({
      where: { id: req.params.id as string },
    });
    res.json({ success: true, data: null });
  } catch (error) {
    res.status(400).json({ success: false, error: "Failed to delete post" });
  }
});

// GET /api/posts/stats/summary
postRouter.get("/stats/summary", async (_req: Request, res: Response) => {
  try {
    const [totalPosts, publishedPosts, topAuthors] = await Promise.all([
      prisma.post.count(),
      prisma.post.count({ where: { published: true } }),
      prisma.user.findMany({
        select: {
          id: true,
          name: true,
          _count: { select: { posts: true, comments: true } },
        },
        orderBy: { posts: { _count: "desc" } },
        take: 10,
      }),
    ]);

    res.json({
      success: true,
      data: { totalPosts, publishedPosts, topAuthors },
    });
  } catch (error) {
    res.status(500).json({ success: false, error: "Failed to fetch stats" });
  }
});
