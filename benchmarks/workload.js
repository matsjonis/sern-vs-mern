import http from "k6/http";
import { check } from "k6";

// One operation type per run, selected with the OP env var:
//   OP=create | update | read | mixed   (default: mixed = 70/20/10 create/update/read)
// Load level per run via VUS; steady measurement window via DURATION.
//
//   k6 run -e BASE_URL=http://localhost:3001 -e VUS=1000 -e OP=create workload.js
//
// One HTTP request per iteration, so throughput == requests/s.

const BASE_URL = __ENV.BASE_URL || "http://localhost:3001";
const VUS = parseInt(__ENV.VUS || "500", 10);
const DURATION = __ENV.DURATION || "30s";
const OP = (__ENV.OP || "mixed").toLowerCase();

export const options = {
  scenarios: {
    load: {

      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: "10s", target: VUS },
        { duration: DURATION, target: VUS },
      ],
    },
  },
  thresholds: {
    http_req_duration: ["p(95)<3000"],
    http_req_failed: ["rate<0.20"],
  },
  tags: { vus: String(VUS), op: OP },
};

const headers = { "Content-Type": "application/json" };

// Pull existing users and posts from the pre-seeded baseline so UPDATE and
// READ target realistically sized data (the runner restores the ~100k snapshot
// before each run).
export function setup() {
  const uRes = http.get(`${BASE_URL}/api/users`, { headers });
  const users = (uRes.json("data") || []).map((u) => u.id).slice(0, 500);

  const pRes = http.get(`${BASE_URL}/api/posts?page=1&pageSize=500`, { headers });
  const posts = (pRes.json("data") || []).map((p) => p.id);

  if (users.length === 0 || posts.length === 0) {
    throw new Error("Baseline not seeded: no users/posts found. Seed/restore before running.");
  }
  return { users, posts };
}

function doCreate(data) {
  const uid = data.users[Math.floor(Math.random() * data.users.length)];
  const res = http.post(
    `${BASE_URL}/api/posts`,
    JSON.stringify({
      title: `Post ${Date.now()}-${Math.random()}`,
      content: "benchmark content ".repeat(20),
      published: Math.random() > 0.5,
      authorId: uid,
    }),
    { headers, tags: { operation: "create_post" } }
  );
  check(res, { "create post 201": (r) => r.status === 201 });
}

function doUpdate(data) {
  const pid = data.posts[Math.floor(Math.random() * data.posts.length)];
  const res = http.put(
    `${BASE_URL}/api/posts/${pid}`,
    JSON.stringify({ title: `Updated ${Date.now()}`, published: Math.random() > 0.5 }),
    { headers, tags: { operation: "update_post" } }
  );
  check(res, { "update post 2xx": (r) => r.status >= 200 && r.status < 300 });
}

function doRead(data) {
  const pid = data.posts[Math.floor(Math.random() * data.posts.length)];
  const res = http.get(`${BASE_URL}/api/posts/${pid}`, { tags: { operation: "read_post" } });
  check(res, { "read post 200": (r) => r.status === 200 });
}

export default function (data) {
  if (OP === "create") return doCreate(data);
  if (OP === "update") return doUpdate(data);
  if (OP === "read") return doRead(data);
  // mixed: 70% create / 20% update / 10% read
  const roll = Math.random();
  if (roll < 0.7) doCreate(data);
  else if (roll < 0.9) doUpdate(data);
  else doRead(data);
}
