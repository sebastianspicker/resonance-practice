/** Default per-route request budget, matching the global rate-limit plugin defaults. */
export const apiRateLimit = {
  max: 100,
  timeWindow: '1 minute',
};
