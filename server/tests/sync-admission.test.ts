// Verifies per-user request and command admission limits without a running server.
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

describe('sync route admission', () => {
  it('bounds authenticated requests and commands independently per user', () => {
    let clock = 0;
    const admission = createSyncAdmission(() => clock);
    for (let index = 0; index < MAX_SYNC_REQUESTS_PER_MINUTE; index += 1) {
      admission.admitRequest('user-1');
    }
    expect(() => admission.admitRequest('user-1')).toThrow(/Too many sync requests/);
    admission.admitRequest('user-2');

    admission.admitCommands('user-2', MAX_SYNC_COMMANDS_PER_MINUTE);
    expect(() => admission.admitCommands('user-2', 1)).toThrow(/Too many sync commands/);

    clock += 60_000;
    expect(() => admission.admitRequest('user-1')).not.toThrow();
  });
});

describe('sync receipt quota', () => {
  it('fails closed rather than evicting an unexpired idempotency receipt', () => {
    expect(() => assertSyncReceiptCapacity(MAX_SYNC_RECEIPTS_PER_USER - 1)).not.toThrow();
    expect(() => assertSyncReceiptCapacity(MAX_SYNC_RECEIPTS_PER_USER)).toThrow(
      /Sync receipt quota reached/
    );
  });
});
