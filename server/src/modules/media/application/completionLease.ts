/** Completion-claim lease timing shared by completion claims and deletion scheduling. */
import { config } from '../../../platform/config.js';

const COMPLETION_CLAIM_SETTLEMENT_MS = 5_000;

/** Keep a completion claim alive across the whole storage budget plus settlement. */
function artifactCompletionClaimLeaseMs() {
  return config.dependencyTimeoutMs + COMPLETION_CLAIM_SETTLEMENT_MS;
}

/** Return the lease deadline, or the epoch when no claim is active. */
export function artifactCompletionClaimLeaseEnd(claimedAt: Date | null) {
  return claimedAt ? new Date(claimedAt.getTime() + artifactCompletionClaimLeaseMs()) : new Date(0);
}
