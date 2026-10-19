///|
async fn release_delete_asset_fixture(
  args : Array[String],
  responses : Array[@github.RawResponse],
  repository? : @github_cli.RepositoryContext,
) -> (@github_cli.Output, Array[(String, String)]) {
  let seen : Array[(String, String)] = []
  let transport = @github.Transport::new(send=request => {
    seen.push((request.verb(), request.path()))
    assert_eq(request.body(), None)
    match responses.get(seen.length() - 1) {
      Some(response) => Ok(response)
      None => fail("unexpected release asset request")
    }
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let options = match @github_cli.parse(args) {
    @github_cli.Business(value) => value
    _ => fail("expected release business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
    repository?,
  )
  (output, seen)
}

///|
async test "release delete-asset resolves tag and exact asset name with explicit repository" {
  let (output, seen) = release_delete_asset_fixture(
    [
      "release", "delete-asset", "v1/2026", "bundle.zip", "-R", "acme/widgets", "--yes",
    ],
    [
      @github.RawResponse::new(
        status=200,
        body=b"{\"id\":123,\"assets\":[{\"id\":77,\"name\":\"bundle.zip.sig\"},{\"id\":5000000000,\"name\":\"bundle.zip\"}]}",
      ),
      @github.RawResponse::new(status=204, body=b""),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stdout(), "")
  assert_eq(seen, [
    ("GET", "/repos/acme/widgets/releases/tags/v1%2F2026"),
    ("DELETE", "/repos/acme/widgets/releases/assets/5000000000"),
  ])
}

///|
async test "release delete-asset accepts repository context and literal latest tag" {
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  let (output, seen) = release_delete_asset_fixture(
    ["release", "delete-asset", "latest", "bundle.zip"],
    [
      @github.RawResponse::new(
        status=200,
        body=b"{\"assets\":[{\"id\":77,\"name\":\"bundle.zip\"}]}",
      ),
      @github.RawResponse::new(status=204, body=b""),
    ],
    repository~,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen, [
    ("GET", "/repos/acme/widgets/releases/tags/latest"),
    ("DELETE", "/repos/acme/widgets/releases/assets/77"),
  ])
}

///|
async test "release delete-asset rejects missing or extra arguments before network" {
  for
    positionals in [
      [],
      ["v1"],
      ["v1", ""],
      ["", "bundle.zip"],
      ["v1", "bundle.zip", "other.zip"],
    ] {
    let args = ["release", "delete-asset", "-R", "acme/widgets"]
    args.append(positionals)
    let (output, seen) = release_delete_asset_fixture(args, [])
    assert_true(output.exit_code() != 0)
    assert_eq(seen.length(), 0)
  }
}

///|
async test "release delete-asset rejects missing and case-mismatched asset names" {
  for name in ["missing.zip", "BUNDLE.ZIP", "bundle*"] {
    let (output, seen) = release_delete_asset_fixture(
      ["release", "delete-asset", "v1", name, "-R", "acme/widgets"],
      [
        @github.RawResponse::new(
          status=200,
          body=b"{\"assets\":[{\"id\":77,\"name\":\"bundle.zip\"}]}",
        ),
      ],
    )
    assert_true(output.exit_code() != 0)
    assert_true(output.stderr().contains("asset not found"))
    assert_eq(seen.length(), 1)
  }
}

///|
async test "release delete-asset never deletes on malformed or ambiguous metadata" {
  for
    body in [
      b"not JSON", b"[]", b"{}", b"{\"assets\":{}}", b"{\"assets\":[null]}", b"{\"assets\":[{\"id\":77}]}",
      b"{\"assets\":[{\"name\":\"bundle.zip\"}]}", b"{\"assets\":[{\"name\":\"bundle.zip\",\"id\":\"77/../../tags/v1\"}]}",
      b"{\"assets\":[{\"name\":\"bundle.zip\",\"id\":0}]}", b"{\"assets\":[{\"name\":\"bundle.zip\",\"id\":-1}]}",
      b"{\"assets\":[{\"name\":\"bundle.zip\",\"id\":1.5}]}", b"{\"assets\":[{\"name\":\"bundle.zip\",\"id\":9999999999999999999999999999}]}",
      b"{\"assets\":[{\"name\":\"bundle.zip\",\"id\":77},{\"name\":\"bundle.zip\",\"id\":88}]}",
    ] {
    let (output, seen) = release_delete_asset_fixture(
      ["release", "delete-asset", "v1", "bundle.zip", "-R", "acme/widgets"],
      [@github.RawResponse::new(status=200, body~)],
    )
    assert_true(output.exit_code() != 0)
    assert_eq(seen.length(), 1)
  }
}

///|
async test "release delete-asset preserves metadata and delete HTTP failures" {
  for status in [401, 403, 404, 422, 500] {
    let error = @github.RawResponse::new(
      status~,
      body=b"{\"message\":\"fixture release failure\"}",
    )
    let args = [
      "release", "delete-asset", "v1", "bundle.zip", "-R", "acme/widgets",
    ]
    let (lookup_output, lookup_seen) = release_delete_asset_fixture(args, [
      error,
    ])
    assert_true(lookup_output.exit_code() != 0)
    assert_true(lookup_output.stderr().contains(status.to_string()))
    assert_true(lookup_output.stderr().contains("fixture release failure"))
    assert_eq(lookup_seen.length(), 1)
    let (delete_output, delete_seen) = release_delete_asset_fixture(args, [
      @github.RawResponse::new(
        status=200,
        body=b"{\"assets\":[{\"id\":77,\"name\":\"bundle.zip\"}]}",
      ),
      error,
    ])
    assert_true(delete_output.exit_code() != 0)
    assert_true(delete_output.stderr().contains(status.to_string()))
    assert_true(delete_output.stderr().contains("fixture release failure"))
    assert_eq(delete_seen.length(), 2)
  }
}

///|
async test "release delete-asset propagates transport cancellation without speculative delete" {
  for fail_on_delete in [false, true] {
    let mut calls = 0
    let transport = @github.Transport::new(send=request => {
      calls += 1
      if fail_on_delete && calls == 1 {
        assert_eq(request.verb(), "GET")
        Ok(
          @github.RawResponse::new(
            status=200,
            body=b"{\"assets\":[{\"id\":77,\"name\":\"bundle.zip\"}]}",
          ),
        )
      } else {
        Err(@github.TransportError::Cancelled)
      }
    })
    let client = match
      @github.Client::new(
        config=@github.ClientConfig::new(base_url="https://api.github.example"),
        transport~,
      ) {
      Ok(value) => value
      Err(_) => fail("fixture client setup failed")
    }
    let options = match
      @github_cli.parse([
        "release", "delete-asset", "v1", "bundle.zip", "-R", "acme/widgets",
      ]) {
      @github_cli.Business(value) => value
      _ => fail("expected release business invocation")
    }
    let output = @native.execute_github_business(
      options,
      client~,
      base_url="https://api.github.example",
    )
    assert_true(output.exit_code() != 0)
    assert_true(output.stderr().contains("cancelled"))
    assert_eq(calls, if fail_on_delete { 2 } else { 1 })
  }
}
