///|
async fn account_fixture(
  args : Array[String],
  responses : Array[@github.RawResponse],
) -> (@github_cli.Output, Array[@github.Request], Array[String]) {
  let seen : Array[@github.Request] = []
  let traces : Array[String] = []
  guard @github.Client::new(
      config=@github.ClientConfig::new(
        base_url="https://api.github.example",
        token="account-fixture-token",
        trace_observer=record => traces.push(record.to_json_line()),
      ),
      transport=@github.Transport::new(send=request => {
        seen.push(request)
        match responses.get(seen.length() - 1) {
          Some(value) => Ok(value)
          None => fail("unexpected account request")
        }
      }),
    )
    is Ok(client) else {
    fail("fixture client setup failed")
  }
  guard @github_cli.parse(args) is @github_cli.Business(options) else {
    fail("expected business command")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  (output, seen, traces)
}

///|
fn account_fixture_response(value : Json) -> @github.RawResponse {
  @github.RawResponse::new(status=200, body=@utf8.encode(value.stringify()))
}

///|
fn account_fixture_body(request : @github.Request) -> Json raise {
  guard request.body() is Some(body) else { fail("request body missing") }
  @json.parse(@utf8.decode(body))
}

///|
async test "account SSH and GPG add read public key files and preserve text" {
  let directory = @fs.tmpdir(prefix="gh-account-key-")
  defer @fs.rmdir(directory, recursive=true)
  let file = directory + "/public-key.txt"
  for
    (command, kind, resource, field) in [
      ("ssh-key", "authentication", "keys", "key"),
      ("ssh-key", "signing", "ssh_signing_keys", "key"),
      ("gpg-key", "", "gpg_keys", "armored_public_key"),
    ] {
    let key = if command == "gpg-key" {
      "-----BEGIN PGP PUBLIC KEY BLOCK-----\nfixture-key-marker\n-----END PGP PUBLIC KEY BLOCK-----\n"
    } else {
      "ssh-ed25519 AAAAfixture-key-marker public@test\n"
    }
    @fs.write_file(file, @utf8.encode(key))
    let args = [command, "add", file, "-t", "123"]
    if !kind.is_empty() {
      args.append(["--type", kind])
    }
    let (output, seen, traces) = account_fixture(args, [
      account_fixture_response({ "id": 1 }),
    ])
    assert_eq(output.exit_code(), 0)
    assert_eq(output.stdout(), "")
    assert_eq(seen.length(), 1)
    assert_eq(seen[0].verb(), "POST")
    assert_eq(seen[0].path(), "/user/" + resource)
    guard account_fixture_body(seen[0]) is Object(fields) else {
      fail("bad key body")
    }
    assert_eq(fields.get(field), Some(Json::string(key)))
    assert_eq(
      fields.get(if command == "gpg-key" { "name" } else { "title" }),
      Some(Json::string("123")),
    )
    for trace in traces {
      assert_false(trace.contains("account-fixture-token"))
      assert_false(trace.contains("fixture-key-marker"))
    }
  }
}

///|
async test "account SSH list includes signing keys and delete resolves key type" {
  let auth = account_fixture_response([{ "id": 1, "title": "auth" }])
  let signing = account_fixture_response([{ "id": 2, "title": "signing" }])
  let (listed, seen, _) = account_fixture(["ssh-key", "list"], [auth, signing])
  assert_eq(listed.exit_code(), 0)
  assert_true(listed.stdout().contains("authentication"))
  assert_true(listed.stdout().contains("signing"))
  assert_eq(seen.map(request => request.path()), [
    "/user/keys", "/user/ssh_signing_keys",
  ])
  let (deleted, seen, _) = account_fixture(["ssh-key", "delete", "2", "-y"], [
    auth,
    signing,
    @github.RawResponse::new(status=204),
  ])
  assert_eq(deleted.exit_code(), 0)
  assert_eq(seen[2].verb(), "DELETE")
  assert_eq(seen[2].path(), "/user/ssh_signing_keys/2")
  let (missing, seen, _) = account_fixture(
    ["ssh-key", "delete", "99", "--yes"],
    [auth, signing],
  )
  assert_true(missing.exit_code() != 0)
  assert_eq(seen.length(), 2)
}

///|
async test "account gist creation and edits send filename keyed string contents" {
  let directory = @fs.tmpdir(prefix="gh-account-gist-")
  defer @fs.rmdir(directory, recursive=true)
  let source = directory + "/sample.txt"
  @fs.write_file(source, b"false\naccount-gist-marker")
  let (created, seen, traces) = account_fixture(
    ["gist", "create", source, "-d", "123", "-p"],
    [
      account_fixture_response({
        "html_url": "https://gist.github.com/acme/abc123",
      }),
    ],
  )
  assert_eq(created.exit_code(), 0)
  assert_eq(created.stdout(), "https://gist.github.com/acme/abc123\n")
  assert_eq(account_fixture_body(seen[0]), {
    "description": "123",
    "public": true,
    "files": { "sample.txt": { "content": "false\naccount-gist-marker" } },
  })
  for trace in traces {
    assert_false(trace.contains("account-gist-marker"))
  }
  for
    args in [
      ["gist", "edit", "abc123", "--filename", "sample.txt", source],
      ["gist", "edit", "https://gist.github.com/acme/abc123", "-a", source],
    ] {
    let (edited, seen, _) = account_fixture(args, [account_fixture_response({})])
    assert_eq(edited.exit_code(), 0)
    assert_eq(seen[0].verb(), "PATCH")
    assert_eq(seen[0].path(), "/gists/abc123")
    assert_eq(account_fixture_body(seen[0]), {
      "files": { "sample.txt": { "content": "false\naccount-gist-marker" } },
    })
  }
}

///|
async test "account gist rename removal description and view use actual file shapes" {
  let cases : Array[(Array[String], Json)] = [
    (
      ["gist", "rename", "abc123", "old.txt", "new.txt"],
      { "files": { "old.txt": { "filename": "new.txt" } } },
    ),
    (
      ["gist", "edit", "abc123", "-r", "old.txt"],
      { "files": { "old.txt": Json::null() } },
    ),
    (["gist", "edit", "abc123", "--desc", "false"], { "description": "false" }),
  ]
  for (args, body) in cases {
    let (output, seen, _) = account_fixture(args, [account_fixture_response({})])
    assert_eq(output.exit_code(), 0)
    assert_eq(account_fixture_body(seen[0]), body)
  }
  let (viewed, _, _) = account_fixture(
    ["gist", "view", "abc123", "-f", "sample.txt"],
    [
      account_fixture_response({
        "files": { "sample.txt": { "content": "hello" } },
      }),
    ],
  )
  assert_eq(viewed.stdout(), "hello\n")
}

///|
async test "account mutations reject invalid local input without sending requests" {
  for
    args in [
      ["ssh-key", "add", "missing-file", "--type", "invalid"],
      ["ssh-key", "add", "missing-file"],
      ["gpg-key", "delete", "1"],
      ["ssh-key", "delete", "../1", "--yes"],
      ["gist", "rename", "invalid-id", "a", "b"],
      ["gist", "edit", "abc123", "--remove", "../bad"],
      ["gist", "edit", "abc123", "--filename", "sample.txt"],
      ["project", "create", "--owner", "@me"],
      ["project", "edit", "1", "--visibility", "UNKNOWN"],
      ["project", "delete", "bad"],
    ] {
    let (output, seen, _) = account_fixture(args, [])
    assert_true(output.exit_code() != 0)
    assert_eq(seen.length(), 0)
  }
}
