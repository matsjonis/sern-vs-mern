import prisma from "./prisma.js";

async function seedLarge() {
  console.log("Seeding large SERN database (100k posts)...");
  const startTime = Date.now();

  // Clean existing data
  console.log("Cleaning existing data...");
  await prisma.comment.deleteMany();
  await prisma.post.deleteMany();
  await prisma.user.deleteMany();

  // Create 1000 users (to distribute posts across)
  console.log("Creating 1000 users...");
  const userBatches = [];
  for (let i = 0; i < 10; i++) {
    const batch = Array.from({ length: 100 }, (_, j) => ({
      email: `user${i * 100 + j + 1}@example.com`,
      name: `User ${i * 100 + j + 1}`,
    }));
    userBatches.push(prisma.user.createMany({ data: batch }));
  }
  await Promise.all(userBatches);
  
  const users = await prisma.user.findMany();
  console.log(`Created ${users.length} users`);

  // Create 100k posts in batches of 1000
  console.log("Creating 100,000 posts (this will take a few minutes)...");
  let totalPosts = 0;
  
  for (let batch = 0; batch < 100; batch++) {
    const posts = Array.from({ length: 1000 }, (_, i) => {
      const randomUser = users[Math.floor(Math.random() * users.length)];
      return {
        title: `Post ${batch * 1000 + i + 1}`,
        content: `This is the content for post ${batch * 1000 + i + 1}. `.repeat(20),
        published: Math.random() > 0.3,
        authorId: randomUser!.id,
      };
    });
    
    await prisma.post.createMany({ data: posts });
    totalPosts += 1000;
    
    if ((batch + 1) % 10 === 0) {
      console.log(`  Progress: ${totalPosts} / 100,000 posts created`);
    }
  }

  console.log(`Created ${totalPosts} posts`);

  // Create comments (10k comments on random posts)
  console.log("Creating 10,000 comments...");
  const allPosts = await prisma.post.findMany({ take: 10000 });
  
  for (let batch = 0; batch < 10; batch++) {
    const comments = Array.from({ length: 1000 }, (_, i) => {
      const randomPost = allPosts[Math.floor(Math.random() * allPosts.length)];
      const randomUser = users[Math.floor(Math.random() * users.length)];
      return {
        content: `Comment ${batch * 1000 + i + 1}`,
        postId: randomPost!.id,
        authorId: randomUser!.id,
      };
    });
    
    await prisma.comment.createMany({ data: comments });
  }

  const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
  console.log(`\nSeeding complete in ${elapsed}s!`);
  console.log(`- 1,000 users`);
  console.log(`- 100,000 posts`);
  console.log(`- 10,000 comments`);
}

seedLarge()
  .catch((e) => {
    console.error("Seeding failed:", e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());