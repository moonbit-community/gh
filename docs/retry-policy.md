# Bounded read retries

Increment 4 adds retries to the typed MoonHub GET operations, including pipeline
reads. `Client::execute` remains a single attempt regardless of HTTP method.
Every mutation remains a single attempt, including pipeline cancel and rerun.
A trace sink failure never triggers a retry.

`ReadRetryPolicy::default()` permits three total attempts per page, starting with
100 ms of backoff and doubling up to 2,000 ms. The second local delay is 200 ms.
`ReadRetryPolicy::new(max_attempts?, initial_delay_ms?, max_delay_ms?)` validates
1–5 attempts and 0–30,000 ms delays, with initial delay no greater than the cap.
One attempt disables retries. Pass the policy as `Client::new(read_retry=...)`;
`retry_wait=...` injects an async millisecond wait for deterministic tests. Normal
clients use the existing upstream `moonbitlang/async.sleep` implementation.

The retry conditions are deliberately explicit:

| Result | Policy |
| --- | --- |
| Transport error on typed GET | Retry within the budget |
| HTTP 429, 502, 503 or 504 | Retry within the budget |
| HTTP 500 or other status | Return immediately |
| Invalid input, authentication, permission or conflict | Return immediately |
| Malformed successful envelope, resource or pagination link | Return immediately |
| Cancellation | Propagate; do not start another request |
| Raw `execute`, any mutation, or trace sink failure | Never retry |

A single `Retry-After` header containing unsigned decimal seconds provides a
minimum wait. The effective delay is the larger of that minimum and local
backoff. If the minimum exceeds the configured cap, retries stop and the current
HTTP failure is returned. Empty, malformed, duplicate, comma-coalesced and
HTTP-date hints also stop retries. This deliberately avoids retrying earlier
than an uninterpretable server minimum. There is no jitter or wall-clock date
interpretation in this version.

Attempts increase continuously from 1 across retries and pagination under the
caller-supplied `operation_id`. Each actual HTTP attempt produces its own
completion trace with that response's sanitized incoming `X-Request-Id`, status
and duration. Retries do not invent outgoing request IDs. Waiting itself produces
no network trace. The final HTTP failure retains its own request ID, and
`trace_failed` combines sink failures from all attempts and pages.

For a single-response read, even a typed resource decoding error retains the
response status and safe request ID. After multiple pages have been aggregated,
a resource decoding error may refer to an earlier page, so the client does not
assign the final page's request ID to that error. All attempts remain available
in the operation's trace. Envelope and pagination errors are decoded while their
individual response is available and retain its correlation.

Pagination limits and retry limits compose: the default 20-page limit and
three-attempt policy permit at most 60 requests; the maximum supported settings
permit at most 500. Each page's backoff budget is at most
`(max_attempts - 1) * max_delay_ms`. Existing native per-attempt timeouts still
apply. This is not an overall command deadline; SDK callers can apply an outer
async timeout, and cancellation during backoff prevents the next HTTP attempt.

The upstream `moonbitlang/async@0.21.3` retry helper was inspected before adding
this policy. It retries raised exceptions with a fixed strategy. It does not
consume typed `ApiFailure` results or per-response `Retry-After` hints. Using it
here would require artificial exceptions and separate mutable response state.
The project therefore keeps a small bounded MoonHub policy loop, while reusing
upstream async waiting, cancellation and HTTP transport.
