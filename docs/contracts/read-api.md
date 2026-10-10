# Proposed MoonHub v1 read API

This proposed contract defines the JSON read API used by the MoonHub client.
Client behavior is validated against fixtures; MoonHub server approval,
implementation and end-to-end acceptance remain pending.

All routes use `/api/v1`, JSON bodies, and origin-bound Bearer authentication.
These are MoonHub-native routes; `pr`/`mr` command spelling does
not change the Merge Request domain model. Browser cookies, form actions,
database tables and the internal runner API are outside this contract.

## Routes

| Method and path after `/api/v1` | Success data | Fixture |
| --- | --- | --- |
| `GET /meta` | `Meta` | `meta.json` |
| `GET /user` | `User` | `user.json` |
| `GET /repos` | `Repository[]` | `repositories.json` |
| `GET /repos/{owner}/{repo}` | `Repository` | `repository.json` |
| `GET /repos/{owner}/{repo}/issues` | `Issue[]` | `issues.json` |
| `GET /repos/{owner}/{repo}/issues/{number}` | `Issue` | `issue.json` |
| `GET /repos/{owner}/{repo}/merge-requests` | `MergeRequest[]` | `merge-requests.json` |
| `GET /repos/{owner}/{repo}/merge-requests/{number}` | `MergeRequest` | `merge-request.json` |

Fixtures live in [`testdata/read-api/`](../../testdata/read-api/). Repository
listing means repositories visible to the authenticated identity, with access
filtering performed by the server. The server owner must confirm that behavior.
The `/meta` endpoint can be called explicitly; ordinary reads do not silently
make an additional discovery request or require an advertised capability.

## JSON envelope and fields

Successful responses use `{"version":1,"data":T}`; list data is an array,
including the empty array. The envelope version must be numeric `1`, and the
resource must have every required field with the stated type. A redirect, empty
body, HTML page or unknown envelope version does not count as successful typed
data. Unknown object fields are ignored for forward-compatible additions.

`?` below means absent or JSON `null` is accepted; a present non-null value must
have the stated type. CLI JSON serialization includes every DTO field in a fixed
order and emits optional values as JSON scalars or `null`, never MoonBit's
default Option array encoding.

| DTO | Fields in output order |
| --- | --- |
| `Meta` | `api_version: Int` (exactly 1), `server_version: String`, `capabilities: String[]` |
| `User` | `id: DecimalString` (positive), `name_key: String`, `display_name: String`, `is_site_admin: Bool` |
| `Repository` | `owner: String`, `name: String`, `visibility: "public" \| "private"`, `default_branch: String?`, `ssh_url: String?` |
| `Issue` | `number: Int` (positive), `title: String`, `description: String`, `status: "open" \| "closed"`, `author: String?`, `assignee: String?`, `edit_version: DecimalString?`, `updated_at: String?` |
| `MergeRequest` | `number: Int` (positive), `title: String`, `description: String`, `source: String`, `target: String`, `draft: Bool`, `status: "open" \| "closed" \| "merged"`, `version: DecimalString?`, `edit_version: DecimalString?`, `merged_sha: String?`, `job_status: "pending" \| "running" \| "succeeded" \| "failed"?` |

IDs and versions are canonical decimal strings, preserving integers beyond
JSON's exact-number range. No sign, leading zero, fraction, whitespace or
exponent is allowed. Versions may be `"0"`: MoonHub's `current_version` starts at
zero. Resource numbers are exact positive signed 32-bit integers in this
contract; fractional and overflowing values are rejected. This limit must be
revisited if the server needs larger public issue/MR numbers.

Descriptions and titles are resource data and may contain private text. They
may appear in requested command output, but must not appear in errors or trace
records. `author` and `assignee` are name keys, not embedded user objects.
`updated_at`, branch names and SHA strings are preserved as strings; the read
contract does not promise timestamp normalization, branch validation, or SHA
validation. Future API additions should preserve these existing field types.

## Repository reference validation

The SDK accepts exact `owner/name` references. Rules match MoonHub's inspected
`domain/valid_name_key` and `domain/parse_transport_repo`, used by repository
creation:

- Owner: 1–63 lowercase ASCII letters, digits, `_` or `-`; starts with a letter
  or digit; `assets` is reserved.
- Repository: 1–100 ASCII letters, digits, `_`, `-` or `.`; starts with a letter
  or digit; case is preserved.
- A `.git` suffix in an API reference is part of the actual repository name.
  This API does not accept SSH/HTTPS clone URLs or strip their suffixes.

References built with `RepositoryRef::new` are revalidated before a request.
This rejects path traversal, query injection and percent-encoded alternatives
without needing a separate URL-escaping implementation.

## Pagination

Lists accept `page` (default 1, valid 1–1,000,000) and `per_page` (default 30,
valid 1–100). The server returns a `Link` header for the next page, for example:

```text
Link: </api/v1/repos/team/demo/issues?page=2&per_page=30>; rel="next"
```

Without `paginate`, the SDK returns one page and the validated SDK-relative
next path. With `paginate`, it aggregates complete pages into one typed array.
The default budget is 20 pages (configurable 1–100) and 1,000 items. Reaching a
budget while more data remains fails explicitly rather than silently reporting
a complete result. A malformed resource anywhere discards the typed aggregate.

Only the same origin and resource path may be followed; page size stays fixed,
and each next page must be exactly the preceding page plus one. Duplicate or
ambiguous next relations, unexpected query parameters, redirects, cycles and
malformed links fail. Next links are validated even in single-page mode.
Every case-insensitive Link field is combined before parsing, with a combined
64 KiB ASCII limit; duplicate next relations cannot hide in separate fields.
An absent next link marks completion, regardless of page length. Every network
attempt shares the caller's operation ID and has an increasing attempt number.
Typed GETs may retry only the bounded transient conditions in
the [read retry policy](../guides/retries.md). Retries and pages share one continuous
attempt sequence; writes and raw `execute` remain single-attempt.

## Errors and observability

HTTP errors use status-authoritative decoding and sanitized
request IDs. Server error prose is not displayed. The fixture
`error-forbidden.json` illustrates the existing v1 error envelope.

`ReadResult[T]` carries `value`, `trace_failed`, `pages`, `next`, and `etag`.
An individual resource read validates a supplied strong ETag;
absent tags remain null, and list results have no individual resource tag.
Callers pass a server-issued tag explicitly to conditional writes; tags are not
constructed from DTO version fields. Read JSON includes the corresponding `etag`
field. MR data includes optional `job_status` to inspect asynchronous merges.
See the [mutation contract](mutation-api.md). Transport,
HTTP, envelope, resource-schema and pagination failures are explicit errors;
there is no partial typed success. `pages` counts successfully decoded envelopes,
not necessarily successfully decoded DTOs. A resource-schema failure therefore
may report nonzero pages. No response body or decoder detail is copied into a
schema failure message. Single-response schema failures retain
the successful HTTP status and safe request ID in `ApiFailure`. A multi-page
aggregate can contain an invalid item from any page, so no single response ID is
assigned to that schema failure; its individual attempts remain traceable.

Trace records describe HTTP attempts. A successful HTTP attempt can still be
followed by a schema Decode error in the SDK result; the HTTP trace is not
rewritten or duplicated after decoding. Trace sink errors remain independent
of request success and accumulate across pagination and retries.

## Server integration requirements

Before calling this contract MoonHub-compatible, the server owner must approve
the route/envelope/field definitions, token permissions and visibility filtering,
pagination links and limits. Server implementation and an end-to-end run against
that implementation are separate acceptance work. Client mutations and
ETag/If-Match are covered by the [mutation contract](mutation-api.md); the
[pipeline contract](pipeline-api.md) defines proposed pipeline
client operations. Real server endpoints and token issuance remain pending.
