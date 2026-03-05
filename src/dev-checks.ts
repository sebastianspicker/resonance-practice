export function createDevSummary() {
  return { scope: "dev", status: "ready" };
}

// current lane: dev
export function devTask() {
  return { scope: "dev", status: "ready" };
}
