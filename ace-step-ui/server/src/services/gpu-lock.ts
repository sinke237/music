// Simple lock to prevent concurrent Wan jobs from causing OOM
// This ensures that even if jobs are queued, they execute one by one
// if necessary, or at least provides a mechanism to limit concurrency.

let isLocked = false;

export async function runWithGpuLock<T>(task: () => Promise<T>): Promise<T> {
  while (isLocked) {
    await new Promise(resolve => setTimeout(resolve, 1000));
  }
  isLocked = true;
  try {
    return await task();
  } finally {
    isLocked = false;
  }
}
