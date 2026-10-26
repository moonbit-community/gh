///|
async test "acceptance refusal happens before a request can connect" {
  let directory = @fs.tmpdir(prefix="gh-scope-policy-")
  defer @fs.rmdir(directory, recursive=true)
  let policy_path = directory + "/policy.json"
  @fs.write_file(policy_path, "{\"schema\":1,\"permits\":[]}")
  let request = @gh.RawRequest::new(
    verb="DELETE",
    path="/repos/ZSeanYves/other",
  )
  let transport = native_raw_transport(
    base_url="http://127.0.0.1:1",
    timeout_ms=100,
    acceptance_policy=policy_path,
  )
  try transport.send(request) catch {
    InvalidRequest => ()
    _ => fail("unexpected refusal")
  } noraise {
    _ => fail("out of scope write reached the transport")
  }
  check_acceptance_request(
    Some(policy_path),
    "https://api.github.com",
    @gh.RawRequest::new(verb="GET", path="/user"),
  )
}

///|
async test "wrong account credentials are rejected before connection or permit consumption" {
  let directory = @fs.tmpdir(prefix="gh-scope-account-")
  defer @fs.rmdir(directory, recursive=true)
  let hash = @crypto.bytes_to_hex_string(@crypto.sha256(b"account-b-token"))
  let ledger = @live_scope.Ledger::for_account(
    "binding", "ZSeanYvesMIN", "321231243", hash,
  )
  ledger.intend_repository("repo", "gh-acceptance-binding-private")
  let body : Json = { "name": "gh-acceptance-binding-private", "private": true }
  let permit = ledger.approve_creation("repo", body)
  let path = directory + "/policy.json"
  @fs.write_file(
    path,
    Json::object({
      "schema": 1,
      "request_id": "0123456789abcdef0123456789abcdef",
      "ledger": ledger.to_json(),
      "permits": [permit.to_json()],
    }).stringify(),
  )
  for
    headers in [
      [],
      [("Authorization", "Bearer account-a-token")],
      [
        ("Authorization", "Bearer account-b-token"),
        ("authorization", "Bearer account-a-token"),
      ],
    ] {
    let request = @gh.RawRequest::new(
      verb="POST",
      path="/user/repos",
      headers~,
      body=@utf8.encode(body.stringify()),
    )
    try
      check_acceptance_request(Some(path), "https://api.github.com", request)
    catch {
      InvalidRequest => ()
      _ => fail("unexpected refusal")
    } noraise {
      _ => fail("wrong credential accepted")
    }
  }
  // The rejected attempts cannot consume the correct account's permit.
  check_acceptance_request(
    Some(path),
    "https://api.github.com",
    @gh.RawRequest::new(
      verb="POST",
      path="/user/repos",
      headers=[("Authorization", "Bearer account-b-token")],
      body=@utf8.encode(body.stringify()),
    ),
  )
}

///|
async test "an exact live write approval is claimed only once before network I/O" {
  let directory = @fs.tmpdir(prefix="gh-scope-claim-")
  defer @fs.rmdir(directory, recursive=true)
  let ledger = @live_scope.Ledger::new("offline", "fixture-id")
  ledger.intend_resource("issue", "fixture", "/issues", "issue")
  let body : Json = { "title": "gh-acceptance-offline-issue" }
  let permit = ledger.approve_creation("issue", body)
  let policy : Json = {
    "schema": 1,
    "request_id": "0123456789abcdef0123456789abcdef",
    "ledger": ledger.to_json(),
    "permits": [permit.to_json()],
  }
  let path = directory + "/policy.json"
  @fs.write_file(path, policy.stringify())
  let request = @gh.RawRequest::new(
    verb="POST",
    path="/repos/ZSeanYves/gh_test/issues",
    body=@utf8.encode(body.stringify()),
  )
  check_acceptance_request(Some(path), "https://api.github.com", request)
  try
    check_acceptance_request(Some(path), "https://api.github.com", request)
  catch {
    InvalidRequest => ()
    _ => fail("unexpected replay failure")
  } noraise {
    _ => fail("write approval replay was accepted")
  }
}
