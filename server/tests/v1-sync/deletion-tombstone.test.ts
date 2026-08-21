import { describe, expect, it } from 'vitest';
import { prisma } from '../support/testUtils.js';
import {
  createEntryCommand,
  enrollCourseMember,
  executeSyncCommands,
  installV1SyncSuite,
} from './support.js';

describe('v1 sync command receipts and versions', () => {
  installV1SyncSuite();
  const create = createEntryCommand;
  const execute = executeSyncCommands;

  it('deletes an entry through the command pipeline and records its tombstone', async () => {
    const entryId = 'v1-entry-delete';
    const deleteToken = await enrollCourseMember('student', 'student-delete', 'Delete Student');
    const created = create('v1-delete-create');
    created.entityId = entryId;
    await execute(deleteToken, [created]);

    const deleted = await execute(deleteToken, [
      {
        operationId: 'v1-delete-apply',
        entityId: entryId,
        kind: 'deleteEntry',
        baseVersion: 1,
        payload: {},
      },
    ]);

    expect(deleted.body.results[0]).toMatchObject({ status: 'applied' });
    await expect(prisma.practiceEntry.findUnique({ where: { id: entryId } })).resolves.toBeNull();
    await expect(
      prisma.deletedEntryTombstone.findUnique({ where: { id: entryId } })
    ).resolves.toMatchObject({ id: entryId });
  });
});
