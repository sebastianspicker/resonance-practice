/** Deadline wrappers that keep remote dependency calls bounded and abortable. */
class OperationTimeoutError extends Error {
  constructor(
    readonly operation: string,
    readonly timeoutMs: number
  ) {
    super(`${operation} timed out after ${timeoutMs}ms`);
    this.name = 'OperationTimeoutError';
  }
}

/**
 * Bound an asynchronous dependency operation and abort it when possible.
 * Promise.race is intentional: the deadline still releases the caller when a
 * mock, driver, or half-open transport ignores AbortSignal.
 */
export async function withDeadline<T>(
  operation: (signal: AbortSignal) => Promise<T>,
  timeoutMs: number,
  label: string
): Promise<T> {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new OperationTimeoutError(label, timeoutMs));
    }, timeoutMs);
  });

  try {
    const work = Promise.resolve().then(() => operation(controller.signal));
    return await Promise.race([work, timeout]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/** Return false when a promise does not settle within the shutdown grace. */
export async function settlesWithin<T>(
  promise: Promise<T>,
  timeoutMs: number,
  label: string
): Promise<boolean> {
  try {
    await withDeadline(() => promise, timeoutMs, label);
    return true;
  } catch (error) {
    if (error instanceof OperationTimeoutError) return false;
    throw error;
  }
}
