const KNOWN_ERRORS = [
  "NotAllowlistedReviewer",
  "PreferredReviewerMismatch",
  "InvalidStatus",
  "DeadlinePassed",
  "DeadlineNotReached",
  "NotAuthorized",
  "InvalidReportHash",
  "ZeroAmount",
  "TransferFailed",
];

export function friendlyErrorMessage(error: unknown) {
  const message = typeof error === "object" && error && "message" in error ? String(error.message) : String(error);
  for (const known of KNOWN_ERRORS) {
    if (message.includes(known)) {
      return known;
    }
  }
  return "Transaction failed";
}
