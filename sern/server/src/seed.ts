import prisma from "./prisma.js";

async function seed() {
  console.log("Seeding SERN database...");

  // Clean existing data
  await prisma.comment.deleteMany();
  await prisma.post.deleteMany();
  await prisma.user.deleteMany();

  // Create users
  const users = await Promise.all(
    Array.from({ length: 10 }, (_, i) =>
      prisma.user.create({
        data: {
          email: `user${i + 1}@example.com`,
          name: `User ${i + 1}`,
        },
      })
    )
  );

  console.log(`Created ${users.length} users`);

  // Create posts
  const posts = [];
  for (const user of users) {
    for (let i = 0; i < 5; i++) {
      const post = await prisma.post.create({
        data: {
          title: `Post ${i + 1} by ${user.name}`,
          content: `This is the content of post ${i + 1} by ${user.name}. `.repeat(10),
          published: Math.random() > 0.3,
          authorId: user.id,
        },
      });
      posts.push(post);
    }
  }

  console.log(`Created ${posts.length} posts`);

  // Create comments
  let commentCount = 0;
  for (const post of posts) {
    const numComments = Math.floor(Math.random() * 5) + 1;
    for (let i = 0; i < numComments; i++) {
      const randomUser = users[Math.floor(Math.random() * users.length)];
      await prisma.comment.create({
        data: {
          content: `Comment ${i + 1} on "${post.title}"`,
          postId: post.id,
          authorId: randomUser.id,
        },
      });
      commentCount++;
    }
  }

  console.log(`Created ${commentCount} comments`);
  console.log("Seeding complete!");
}

seed()
  .catch((e) => {
    console.error("Seeding failed:", e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());