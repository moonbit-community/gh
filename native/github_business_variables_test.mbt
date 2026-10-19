///|
/// Each tuple defines an exact request followed by the server response.
/// Missing, extra, or reordered requests fail the fixture immediately.
async fn variable_set_fixture(
  args : Array[String],
  expected : Array[(String, String, Json, Int32, Bytes)],
) -> @github_cli.Output {
  let mut calls = 0
  let transport = @github.Transport::new(send=request => {
    guard expected.get(calls) is Some((verb, path, body, status, response)) else {
      fail("unexpected variable request")
    }
    calls += 1
    assert_eq(request.verb(), verb)
    assert_eq(request.path(), path)
    guard request.body() is Some(actual) else {
      fail("variable request body missing")
    }
    let actual = @json.parse(@utf8.decode(actual)) catch {
      _ => fail("variable request body is not JSON")
    }
    assert_eq(actual, body)
    Ok(@github.RawResponse::new(status~, body=response))
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
    _ => fail("expected business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(calls, expected.length())
  output
}

///|
async test "variable set POSTs repository collection preserving name and string value" {
  for value in ["001", "true", "null", "{\"key\":1}", "line one\nline two"] {
    let body = Json::object(
      Map([
        ("name", Json::string("build_number")),
        ("value", Json::string(value)),
      ]),
    )
    let output = variable_set_fixture(
      ["variable", "set", "build_number", "-R", "acme/widgets", "--body", value],
      [("POST", "/repos/acme/widgets/actions/variables", body, 201, b"")],
    )
    assert_eq(output.exit_code(), 0)
    assert_eq(output.stdout(), "")
    assert_eq(output.stderr(), "")
  }
}

///|
async test "variable set PATCHes repository item only after create conflict" {
  let output = variable_set_fixture(
    ["variable", "set", "BUILD_NUMBER", "-R", "acme/widgets", "--body", "002"],
    [
      (
        "POST",
        "/repos/acme/widgets/actions/variables",
        { "name": "BUILD_NUMBER", "value": "002" },
        409,
        b"{\"message\":\"variable already exists\"}",
      ),
      (
        "PATCH",
        "/repos/acme/widgets/actions/variables/BUILD_NUMBER",
        { "value": "002" },
        204,
        b"",
      ),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stdout(), "")
  assert_eq(output.stderr(), "")
}

///|
async test "variable set defaults organization visibility to private on POST and PATCH" {
  let output = variable_set_fixture(
    ["variable", "set", "BUILD_NUMBER", "--org", "acme", "--body", "003"],
    [
      (
        "POST",
        "/orgs/acme/actions/variables",
        { "name": "BUILD_NUMBER", "value": "003", "visibility": "private" },
        409,
        b"{}",
      ),
      (
        "PATCH",
        "/orgs/acme/actions/variables/BUILD_NUMBER",
        { "value": "003", "visibility": "private" },
        204,
        b"",
      ),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stdout(), "")
  assert_eq(output.stderr(), "")
}

///|
async test "variable set preserves explicit organization visibility on POST and PATCH" {
  let output = variable_set_fixture(
    [
      "variable", "set", "BUILD_NUMBER", "--org", "acme", "--visibility", "all",
      "--body", "004",
    ],
    [
      (
        "POST",
        "/orgs/acme/actions/variables",
        { "name": "BUILD_NUMBER", "value": "004", "visibility": "all" },
        409,
        b"{}",
      ),
      (
        "PATCH",
        "/orgs/acme/actions/variables/BUILD_NUMBER",
        { "value": "004", "visibility": "all" },
        204,
        b"",
      ),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stdout(), "")
  assert_eq(output.stderr(), "")
}

///|
async test "variable set routes environment creation and update to the environment" {
  let output = variable_set_fixture(
    [
      "variable", "set", "BUILD_NUMBER", "-R", "acme/widgets", "--env", "staging",
      "--body", "005",
    ],
    [
      (
        "POST",
        "/repos/acme/widgets/environments/staging/variables",
        { "name": "BUILD_NUMBER", "value": "005" },
        409,
        b"{}",
      ),
      (
        "PATCH",
        "/repos/acme/widgets/environments/staging/variables/BUILD_NUMBER",
        { "value": "005" },
        204,
        b"",
      ),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stdout(), "")
  assert_eq(output.stderr(), "")
}

///|
async test "variable set preserves failed POST responses without PATCH" {
  for status in [401, 403, 404, 422, 500] {
    let output = variable_set_fixture(
      [
        "variable", "set", "BUILD_NUMBER", "-R", "acme/widgets", "--body", "fixture-value",
      ],
      [
        (
          "POST",
          "/repos/acme/widgets/actions/variables",
          { "name": "BUILD_NUMBER", "value": "fixture-value" },
          status,
          b"{\"message\":\"fixture request denied\"}",
        ),
      ],
    )
    assert_eq(output.exit_code(), if status == 401 { 4 } else { 1 })
    assert_eq(output.stdout(), "{\"message\":\"fixture request denied\"}")
    assert_true(output.stderr().contains("fixture request denied"))
    assert_false(output.stderr().contains("fixture-value"))
  }
}

///|
async test "variable set preserves failed PATCH responses without further retries" {
  for status in [403, 404, 409, 422, 500] {
    let output = variable_set_fixture(
      [
        "variable", "set", "BUILD_NUMBER", "-R", "acme/widgets", "--body", "fixture-value",
      ],
      [
        (
          "POST",
          "/repos/acme/widgets/actions/variables",
          { "name": "BUILD_NUMBER", "value": "fixture-value" },
          409,
          b"{\"message\":\"variable already exists\"}",
        ),
        (
          "PATCH",
          "/repos/acme/widgets/actions/variables/BUILD_NUMBER",
          { "value": "fixture-value" },
          status,
          b"{\"message\":\"fixture update denied\"}",
        ),
      ],
    )
    assert_eq(output.exit_code(), 1)
    assert_eq(output.stdout(), "{\"message\":\"fixture update denied\"}")
    assert_true(output.stderr().contains("fixture update denied"))
    assert_false(output.stderr().contains("fixture-value"))
  }
}

///|
async test "variable set never prints values echoed in successful response bodies" {
  let output = variable_set_fixture(
    [
      "variable", "set", "BUILD_NUMBER", "-R", "acme/widgets", "--body", "fixture-value",
    ],
    [
      (
        "POST",
        "/repos/acme/widgets/actions/variables",
        { "name": "BUILD_NUMBER", "value": "fixture-value" },
        201,
        b"{\"name\":\"BUILD_NUMBER\",\"value\":\"fixture-value\"}",
      ),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stdout(), "")
  assert_eq(output.stderr(), "")
}
