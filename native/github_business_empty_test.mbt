///|
/// Exercise the business command seam without network access or credentials.
/// These payloads retain the collection envelopes returned by GitHub REST.
async fn empty_business_fixture_output(
  args : Array[String],
  expected_path : String,
  body : Bytes,
  status : Int32,
) -> @github_cli.Output {
  let transport = @github.Transport::new(send=request => {
    assert_eq(request.verb(), "GET")
    assert_eq(request.path(), expected_path)
    Ok(@github.RawResponse::new(status~, body~))
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
  @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
}

///|
async test "run list projects an empty workflow_runs collection as an array" {
  let output = empty_business_fixture_output(
    [
      "run", "list", "-R", "acme/widgets", "--json", "databaseId,status,conclusion,name",
    ],
    "/repos/acme/widgets/actions/runs",
    b"{\"total_count\":0,\"workflow_runs\":[]}",
    200,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stderr(), "")
  assert_eq(output.stdout(), "[]\n")
}

///|
async test "workflow list keeps an empty workflows collection silent" {
  for
    flags in [
      [],
      ["--json", "id,name,state"],
      ["--all"],
      ["--all", "--json", "id,name,state"],
      ["-a", "--json", "id,name,state"],
      ["--all=true", "--json", "id,name,state"],
    ] {
    let args = ["workflow", "list", "-R", "acme/widgets"]
    for flag in flags {
      args.push(flag)
    }
    let output = empty_business_fixture_output(
      args, "/repos/acme/widgets/actions/workflows", b"{\"total_count\":0,\"workflows\":[]}",
      200,
    )
    assert_eq(output.exit_code(), 0)
    assert_eq(output.stderr(), "")
    assert_eq(output.stdout(), "")
  }
}

///|
async test "workflow list keeps empty results silent with jq and template" {
  let jq_output = empty_business_fixture_output(
    [
      "workflow", "list", "-R", "acme/widgets", "--json", "id,name", "--jq", ".[]",
    ],
    "/repos/acme/widgets/actions/workflows",
    b"{\"total_count\":0,\"workflows\":[]}",
    200,
  )
  assert_eq(jq_output.exit_code(), 0)
  assert_eq(jq_output.stdout(), "")
  assert_eq(jq_output.stderr(), "")
  let template_output = empty_business_fixture_output(
    [
      "workflow", "list", "-R", "acme/widgets", "--json", "id,name", "--template",
      "{{.name}}",
    ],
    "/repos/acme/widgets/actions/workflows",
    b"{\"total_count\":0,\"workflows\":[]}",
    200,
  )
  assert_eq(template_output.exit_code(), 0)
  assert_eq(template_output.stdout(), "")
  assert_eq(template_output.stderr(), "")
}

///|
async test "workflow list filters disabled states before JSON projection" {
  let body =
    #|{
    #|  "total_count": 5,
    #|  "workflows": [
    #|    {"id": 1, "name": "CI", "state": "active"},
    #|    {"id": 2, "name": "Manual", "state": "disabled_manually"},
    #|    {"id": 3, "name": "Inactive", "state": "disabled_inactivity"},
    #|    {"id": 4, "name": "Deleted", "state": "deleted"},
    #|    {"id": 5, "name": "Unknown", "state": "future_state"}
    #|  ]
    #|}
  for flags in [[], ["--all=false"]] {
    let args = [
      "workflow", "list", "-R", "acme/widgets", "--json", "id,name,state",
    ]
    for flag in flags {
      args.push(flag)
    }
    let output = empty_business_fixture_output(
      args,
      "/repos/acme/widgets/actions/workflows",
      @utf8.encode(body),
      200,
    )
    assert_eq(output.exit_code(), 0)
    assert_eq(output.stderr(), "")
    assert_eq(@json.parse(output.stdout()), [
      { "id": 1, "name": "CI", "state": "active" },
    ])
  }
  for flag in ["--all", "-a", "--all=true"] {
    let output = empty_business_fixture_output(
      ["workflow", "list", "-R", "acme/widgets", "--json", "id", flag],
      "/repos/acme/widgets/actions/workflows",
      @utf8.encode(body),
      200,
    )
    assert_eq(output.exit_code(), 0)
    assert_eq(output.stderr(), "")
    assert_eq(@json.parse(output.stdout()), [
      { "id": 1 },
      { "id": 2 },
      { "id": 3 },
      { "id": 4 },
      { "id": 5 },
    ])
  }
}

///|
async test "workflow list is silent when every workflow is disabled" {
  let body = b"{\"total_count\":1,\"workflows\":[{\"id\":9,\"state\":\"disabled_manually\"}]}"
  for
    flags in [
      [],
      ["--json", "id"],
      ["--json", "id", "--jq", "length"],
      ["--json", "id", "--template", "fixed text"],
    ] {
    let args = ["workflow", "list", "-R", "acme/widgets"]
    for flag in flags {
      args.push(flag)
    }
    let output = empty_business_fixture_output(
      args, "/repos/acme/widgets/actions/workflows", body, 200,
    )
    assert_eq(output.exit_code(), 0)
    assert_eq(output.stderr(), "")
    assert_eq(output.stdout(), "")
  }
}

///|
async test "workflow list HTTP failures remain visible with an empty collection" {
  let body = b"{\"message\":\"Resource not accessible by integration\",\"workflows\":[]}"
  let output = empty_business_fixture_output(
    ["workflow", "list", "-R", "acme/widgets", "--json", "id"],
    "/repos/acme/widgets/actions/workflows",
    body,
    403,
  )
  assert_eq(output.exit_code(), 1)
  assert_eq(output.stdout_bytes(), body)
  assert_true(
    output
    .stderr()
    .contains("gh: Resource not accessible by integration (HTTP 403)"),
  )
}

///|
async test "raw workflow API keeps its unfiltered collection envelope" {
  let body = b"{\"total_count\":1,\"workflows\":[{\"id\":9,\"state\":\"disabled_manually\"}]}"
  let transport = @github.Transport::new(send=request => {
    assert_eq(request.path(), "/repos/acme/widgets/actions/workflows")
    Ok(@github.RawResponse::new(status=200, body~))
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
    @github_cli.parse(["api", "repos/acme/widgets/actions/workflows"]) {
    @github_cli.Api(value) => value
    _ => fail("expected API invocation")
  }
  let output = @native.execute_github_api(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stderr(), "")
  assert_eq(output.stdout_bytes(), body)
}

///|
async test "search repos projects an empty items collection as an array" {
  let output = empty_business_fixture_output(
    ["search", "repos", "widgets", "--json", "fullName"],
    "/search/repositories",
    b"{\"total_count\":0,\"incomplete_results\":false,\"items\":[]}",
    200,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stderr(), "")
  assert_eq(output.stdout(), "[]\n")
}

///|
async test "business JSON projection preserves the HTTP 422 error body" {
  let body = b"{\"message\":\"Query must include 'is:issue' or 'is:pull-request'\",\"documentation_url\":\"https://docs.github.com/rest/search/search#search-issues-and-pull-requests\",\"status\":\"422\"}"
  let output = empty_business_fixture_output(
    ["search", "issues", "repo:acme/widgets", "--json", "number,title"],
    "/search/issues",
    body,
    422,
  )
  assert_eq(output.exit_code(), 1)
  assert_eq(output.stdout_bytes(), body)
  assert_true(
    output
    .stderr()
    .contains(
      "gh: Query must include 'is:issue' or 'is:pull-request' (HTTP 422)",
    ),
  )
}

///|
async test "business collections follow REST Link pagination without looping" {
  let first_items : Array[String] = []
  for i in 1..<=100 {
    first_items.push("{\"number\":" + i.to_string() + "}")
  }
  let first_body = @utf8.encode(
    "{\"total_count\":101,\"issues\":[" + first_items.join(",") + "]}",
  )
  let second_body = b"{\"total_count\":101,\"issues\":[{\"number\":101}]}"
  let calls = Ref(0)
  let transport = @github.Transport::new(send=request => {
    calls.val += 1
    assert_eq(request.path(), "/repos/acme/widgets/issues")
    if calls.val == 1 {
      assert_true(request.url().contains("page=1"))
      Ok(
        @github.RawResponse::new(
          status=200,
          headers=[
            (
              "Link", "<https://api.github.example/repos/acme/widgets/issues?per_page=100&page=2>; rel=\"next\"",
            ),
          ],
          body=first_body,
        ),
      )
    } else {
      assert_eq(calls.val, 2)
      assert_true(request.url().contains("page=2"))
      Ok(@github.RawResponse::new(status=200, body=second_body))
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
      "issue", "list", "-R", "acme/widgets", "--limit", "150", "--json", "number",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(calls.val, 2)
  assert_true(output.stdout().contains("101"))
}
