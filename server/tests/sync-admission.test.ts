// Rate admission is independent per user and receipt capacity never evicts an unexpired replay record.
import { describe, expect, it } from 'vitest';
import {
  createSyncAdmission,
  MAX_SYNC_COMMANDS_PER_MINUTE,
  MAX_SYNC_REQUESTS_PER_MINUTE,
} from '../src/services/sync/admission.js';
import {
  assertSyncReceiptCapacity,
  MAX_SYNC_RECEIPTS_PER_USER,
} from '../src/services/syncCommands.js';

describe('sync admission and durable replay capacity', () => {
  it('bounds requests and commands per user, then resets at the time window', () => {
    let now = 0;
    const admission = createSyncAdmission(() => now);
    for (let index = 0; index < MAX_SYNC_REQUESTS_PER_MINUTE; index += 1)
      admission.admitRequest('one');
    expect(() => admission.admitRequest('one')).toThrow(/Too many sync requests/);
    admission.admitRequest('two');
    admission.admitCommands('two', MAX_SYNC_COMMANDS_PER_MINUTE);
    expect(() => admission.admitCommands('two', 1)).toThrow(/Too many sync commands/);
    now += 60_000;
    expect(() => admission.admitRequest('one')).not.toThrow();
  });

  it('fails closed instead of evicting an active command receipt', () => {
    expect(() => assertSyncReceiptCapacity(MAX_SYNC_RECEIPTS_PER_USER - 1)).not.toThrow();
    expect(() => assertSyncReceiptCapacity(MAX_SYNC_RECEIPTS_PER_USER)).toThrow(/quota reached/);
  });
});
