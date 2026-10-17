# SDK integration status

Work in progress in `github/` and `internal/github_auth/`; no native or CLI files are changed by this slice.

Available integration APIs:

- `ClientConfig::new(..., trace_observer? : async (TraceRecord) -> Unit)`; `Client::new` optionally overrides the observer and clock.
- `Client::request(request, operation_id?, operation_name?)` preserves the current return type. `Client::graphql_raw(request, operation_id?, operation_name?)` preserves raw request bytes, verb, duplicate headers, and query fields and returns the complete response envelope as bytes.
- `Client::trace_failures()` exposes observer failures independently of request results. Every actual transport attempt has a sanitized trace record; JSON serialization redacts a second time.
- `next_link(link, current_url~)` and `RawResponse::next_url(current_url~)` parse quoted RFC 8288 Link fields and return a same-origin next URL. Callers still own loop/page bounds.
- `graphql_next_cursor(json, page_info_path?)` requires an explicit path when multiple connections exist. `GraphQLRequest::with_cursor(cursor, variable?)` copies variables.
- `RawResponse::rate_limit()` exposes limit, remaining, used, reset epoch, and Retry-After without sleeping.
- `TransportError::Cancelled` maps to `GitHubError::Cancelled`; actual async runtime cancellation is traced and rethrown, so cancellation scopes still work.

REST base URL validation rejects userinfo, query/fragment, invalid DNS/ports, and plaintext non-loopback hosts (including localhost suffix tricks). Configured GraphQL URL must have the same origin. Request headers retain duplicates; hop-by-hop framing headers remain transport-owned. Default requests send once. Explicit retry policy retries GET/HEAD only, never a mutation or cancellation.

GraphQL trace fingerprint is SHA-256 of syntax shape after removing all names, aliases, enum tokens, strings, numbers, comments, and whitespace. It is intentionally not a unique query identity and cannot be used to dictionary-test literal secrets.

Validation and remaining limits will be updated after regression tests complete.
