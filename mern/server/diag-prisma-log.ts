import { PrismaClient } from "@prisma/client";
const prisma = new PrismaClient({ log: [{ emit: "stdout", level: "query" }] });

async function main() {
  const user = await prisma.user.findFirst();
  const post = await prisma.post.findFirst();

  console.log("=== CREATE ===");
  const c = await prisma.post.create({
    data: { title: "diag", content: "diag", published: false, authorId: user!.id },
    include: { author: { select: { id: true, name: true, email: true } } },
  });

  console.log("=== UPDATE ===");
  await prisma.post.update({
    where: { id: post!.id },
    data: { title: "diag2", content: "diag2", published: true },
    include: { author: { select: { id: true, name: true, email: true } } },
  });

  await prisma.post.delete({ where: { id: c.id } });
  await prisma.$disconnect();
}
main();
