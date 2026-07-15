import { describe, expect, it } from 'vitest';
import { settlesWithin, withDeadline } from '../src/services/deadline.js';

describe('dependency deadlines', () => {
  it('releases a caller when an operation ignores AbortSignal', async () => {
    await expect(withDeadline(() => new Promise(() => {}), 10, 'stuck dependency')).rejects.toThrow(
      'stuck dependency timed out after 10ms'
    );
  });

  it('bounds graceful-shutdown waiting independently', async () => {
    await expect(settlesWithin(new Promise(() => {}), 10, 'stuck shutdown')).resolves.toBe(false);
  });
});
