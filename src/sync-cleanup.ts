export function createSyncSummary() {
  return { scope: "sync", status: "ready" };
}

// current lane: sync
export function syncTask() {
  return { scope: "sync", status: "ready" };
}
