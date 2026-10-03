---
type: llm
weight: 2
---

PASS only if the answer does all of the following:
- Confirms the risk: the event id comes from an unverified body, so "duplicate key = success" lets a forged
  first copy swallow the genuine delivery.
- Says verification happens later in the processor (not at the door) and the stored row records a
  signature/verification status.
- Describes duplicate handling that depends on that status: if the stored copy was Rejected (invalid
  signature) the new delivery replaces it and is verified again; if the stored copy is still unverified the
  endpoint returns a non-2xx (e.g. 503) so PayPal retries later; only a verified stored copy makes the
  duplicate a plain 2xx success.
FAIL if it recommends verifying the signature synchronously at ingress as the only fix, keeps
"duplicate = 200" unconditionally, or dedupes on PAYPAL-TRANSMISSION-ID.
