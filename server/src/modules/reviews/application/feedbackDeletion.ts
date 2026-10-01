/** Feedback cleanup for targets that are being deleted in the caller's transaction. */
import type { FeedbackTargetType, Prisma } from '@prisma/client';

/**
 * Delete feedback and markers targeted at an entry or its artifacts. Target
 * rows may have a NULL entryId, so they are matched by target, not by entry.
 */
export async function deleteFeedbackForTargets(
  tx: Prisma.TransactionClient,
  entryId: string,
  artifactIds: string[]
): Promise<void> {
  await deleteTargetFeedback(tx, 'artifact', artifactIds);
  await deleteTargetFeedback(tx, 'entry', [entryId]);
}

async function deleteTargetFeedback(
  tx: Prisma.TransactionClient,
  targetType: FeedbackTargetType,
  targetIds: string[]
) {
  if (targetIds.length === 0) return;

  const feedback = await tx.feedback.findMany({
    where: { targetType, targetId: { in: targetIds } },
    select: { id: true },
  });
  const feedbackIds = feedback.map((feedback) => feedback.id);
  if (feedbackIds.length > 0) {
    await tx.marker.deleteMany({ where: { feedbackId: { in: feedbackIds } } });
    await tx.feedback.deleteMany({ where: { id: { in: feedbackIds } } });
  }
}
