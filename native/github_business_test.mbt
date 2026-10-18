///|
/// Core command fixture tests assert the request seam rather than formatting
/// server data. This is the same boundary used by the native executable, so a
/// real GitHub token is never needed for command coverage.
async test "issue list fixture resolves repository and query" {
  let mut seen_method = ""
  let mut seen_path = ""
  let mut seen_query : Array[(String, String)] = []
  let transport = @github.Transport::new(send=request => {
    seen_method = request.verb()
    seen_path = request.path()
    seen_query = request.query()
    Ok(@github.RawResponse::new(status=200, body=b"[]"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let invocation = @github_cli.parse([
    "issue", "list", "-R", "acme/widgets", "--state", "open", "--limit", "10",
  ])
  let options = match invocation {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen_method, "GET")
  assert_eq(seen_path, "/repos/acme/widgets/issues")
  assert_true(seen_query.contains(("state", "open")))
  assert_true(seen_query.contains(("per_page", "10")))
}

///|
async test "repo view projects nameWithOwner from the REST repository full_name" {
  // Public REST response fields captured from
  // https://api.github.com/repos/octocat/Hello-World on 2026-10-16.
  // Unrelated fields are omitted; no CLI-shaped nameWithOwner is injected.
  let repository_body =
    #|{
    #|  "id": 1296269,
    #|  "node_id": "MDEwOlJlcG9zaXRvcnkxMjk2MjY5",
    #|  "name": "Hello-World",
    #|  "full_name": "octocat/Hello-World",
    #|  "private": false,
    #|  "visibility": "public",
    #|  "owner": {
    #|    "login": "octocat",
    #|    "id": 583231,
    #|    "type": "User"
    #|  },
    #|  "html_url": "https://github.com/octocat/Hello-World",
    #|  "default_branch": "master"
    #|}
  let transport = @github.Transport::new(send=request => {
    assert_eq(request.verb(), "GET")
    let body = match request.path() {
      "/repos/octocat/Hello-World" => repository_body
      _ => fail("unexpected repository request")
    }
    Ok(@github.RawResponse::new(status=200, body=@utf8.encode(body)))
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
      "repo", "view", "-R", "octocat/Hello-World", "--json", "name,nameWithOwner,visibility",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected repo view invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stderr(), "")
  assert_eq(@json.parse(output.stdout()), {
    "name": "Hello-World",
    "nameWithOwner": "octocat/Hello-World",
    "visibility": "PUBLIC",
  })
  // The alias belongs to the selected CLI fields, not the raw REST body.
  let raw_options = match
    @github_cli.parse(["repo", "view", "-R", "octocat/Hello-World"]) {
    @github_cli.Business(value) => value
    _ => fail("expected repo view invocation")
  }
  let raw_output = @native.execute_github_business(
    raw_options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(raw_output.exit_code(), 0)
  assert_eq(@json.parse(raw_output.stdout()), @json.parse(repository_body))
}

///|
async test "pull request create fixture sends JSON body" {
  let mut seen_method = ""
  let mut seen_path = ""
  let mut seen_body : Bytes? = None
  let transport = @github.Transport::new(send=request => {
    seen_method = request.verb()
    seen_path = request.path()
    seen_body = request.body()
    Ok(@github.RawResponse::new(status=201, body=b"{\"number\":3}\n"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let invocation = @github_cli.parse([
    "pr", "create", "-R", "acme/widgets", "--title", "Fix bug", "--body", "Details",
    "--head", "feature", "--base", "main", "--maintainer-can-modify",
  ])
  let options = match invocation {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen_method, "POST")
  assert_eq(seen_path, "/repos/acme/widgets/pulls")
  guard seen_body is Some(body) else { fail("request body was absent") }
  let body_text = @utf8.decode(body) catch { _ => fail("body was not UTF-8") }
  assert_true(body_text.contains("Fix bug"))
  assert_true(body_text.contains("maintainer_can_modify"))
}

///|
async test "search fixture builds encoded query without repository" {
  let mut seen_path = ""
  let mut seen_query : Array[(String, String)] = []
  let transport = @github.Transport::new(send=request => {
    seen_path = request.path()
    seen_query = request.query()
    Ok(@github.RawResponse::new(status=200, body=b"{\"items\":[]}"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let invocation = @github_cli.parse([
    "search", "issues", "bug fix", "--state", "open",
  ])
  let options = match invocation {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen_path, "/search/issues")
  assert_true(seen_query.contains(("q", "\"bug fix\" state:open is:issue")))
  assert_true(seen_query.length() == 1)
}

///|
async test "search keyword formatting preserves gh qualifier boundaries" {
  let mut seen_query : Array[(String, String)] = []
  let transport = @github.Transport::new(send=request => {
    assert_eq(request.verb(), "GET")
    assert_eq(request.path(), "/search/repositories")
    seen_query = request.query()
    Ok(@github.RawResponse::new(status=200, body=b"{\"items\":[]}"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  // Expected q values follow v2.102.0 pkg/search/query.go. Keep single-argv
  // phrases distinct from independently supplied search qualifiers.
  for
    (keywords, expected_query) in [
      (["gh_test in:name user:ZSeanYves"], "gh_test in:\"name user:ZSeanYves\""),
      (
        ["gh_test", "in:name", "user:ZSeanYves"],
        "gh_test in:name user:ZSeanYves",
      ),
      (["vim plugin"], "\"vim plugin\""),
      (["label:good first issue"], "label:\"good first issue\""),
      (["label:area:cli tools"], "label:\"area:cli tools\""),
      (["say \"hello\""], "\"say \\\"hello\\\"\""),
      (["path:docs\\cli guide"], "path:\"docs\\\\cli guide\""),
      (["path:docs\\cli"], "path:docs\\cli"),
      (["tab\tline\n"], "\"tab\\tline\\n\""),
      (["widgets", "--topic", "cli tools"], "widgets topic:\"cli tools\""),
      (["widgets", "--owner", "acme"], "widgets user:acme"),
    ] {
    let args = ["search", "repos"]
    args.append(keywords)
    args.append(["--limit", "3", "--json", "fullName"])
    let options = match @github_cli.parse(args) {
      @github_cli.Business(value) => value
      _ => fail("expected search invocation")
    }
    let output = @native.execute_github_business(
      options,
      client~,
      base_url="https://api.github.example",
    )
    assert_eq(output.exit_code(), 0)
    assert_eq(output.stdout(), "[]\n")
    assert_eq(output.stderr(), "")
    assert_eq(seen_query, [("q", expected_query), ("per_page", "3")])
  }
}

///|
async test "business json output projects requested fields" {
  let transport = @github.Transport::new(send=_ => {
    Ok(
      @github.RawResponse::new(
        status=200,
        body=b"[{\"number\":3,\"title\":\"Fix\",\"body\":\"private\"}]",
      ),
    )
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let invocation = @github_cli.parse([
    "issue", "list", "-R", "acme/widgets", "--json", "number,title",
  ])
  let options = match invocation {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(output.exit_code(), 0)
  assert_true(output.stdout().contains("number"))
  assert_true(output.stdout().contains("title"))
  assert_true(!output.stdout().contains("private"))
}

///|
/// The command seam is also exercised as a small request matrix. These cases
/// intentionally use one injected raw transport so regressions in parser to
/// endpoint mapping are visible without a live GitHub account.
async test "core business commands build GitHub REST requests" {
  let seen : Array[(String, String, Array[(String, String)])] = []
  let transport = @github.Transport::new(send=request => {
    seen.push((request.verb(), request.path(), request.query()))
    Ok(@github.RawResponse::new(status=200, body=b"{}"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }

  let cases : Array[(Array[String], String, String)] = [
    (["repo", "view", "-R", "acme/widgets"], "GET", "/repos/acme/widgets"),
    (
      ["issue", "view", "17", "-R", "acme/widgets"],
      "GET",
      "/repos/acme/widgets/issues/17",
    ),
    (
      ["pr", "list", "-R", "acme/widgets", "--state", "open"],
      "GET",
      "/repos/acme/widgets/pulls",
    ),
    (
      ["release", "view", "v1/2026", "-R", "acme/widgets"],
      "GET",
      "/repos/acme/widgets/releases/tags/v1%2F2026",
    ),
    (
      ["run", "cancel", "99", "-R", "acme/widgets"],
      "POST",
      "/repos/acme/widgets/actions/runs/99/cancel",
    ),
    (
      ["ruleset", "view", "42", "-R", "acme/widgets"],
      "GET",
      "/repos/acme/widgets/rulesets/42",
    ),
    (
      ["release", "delete-asset", "77", "-R", "acme/widgets"],
      "DELETE",
      "/repos/acme/widgets/releases/assets/77",
    ),
    (["search", "code", "hello world"], "GET", "/search/code"),
  ]
  for (args, expected_method, expected_path) in cases {
    let options = match @github_cli.parse(args) {
      @github_cli.Business(value) => value
      _ => fail("expected business invocation")
    }
    let output = @native.execute_github_business(
      options,
      client~,
      base_url="https://api.github.example",
      repository~,
    )
    assert_eq(output.exit_code(), 0)
    let index = seen.length() - 1
    let (verb, path, _) = seen[index]
    assert_eq(verb, expected_method)
    assert_eq(path, expected_path)
  }
  let (_, _, search_query) = seen[seen.length() - 1]
  assert_true(search_query.contains(("q", "\"hello world\"")))
  let (_, _, pr_query) = seen[2]
  assert_true(pr_query.contains(("state", "open")))
  let check_options = match
    @github_cli.parse(["ruleset", "check", "main", "-R", "acme/widgets"]) {
    @github_cli.Business(value) => value
    _ => fail("expected ruleset invocation")
  }
  let check_output = @native.execute_github_business(
    check_options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(check_output.exit_code(), 0)
  let (_, check_path, check_query) = seen[seen.length() - 1]
  assert_eq(check_path, "/repos/acme/widgets/rulesets/rule-suites")
  assert_true(check_query.contains(("ref", "main")))
}

///|
/// Verify command-level defaults that are easy to lose when translating a
/// human-friendly gh command into a generic REST mutation.
async test "business mutations supply gh state and rename defaults" {
  let seen : Array[(String, String, Bytes?)] = []
  let transport = @github.Transport::new(send=request => {
    seen.push((request.verb(), request.path(), request.body()))
    Ok(@github.RawResponse::new(status=200, body=b"{}"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  let close_options = match
    @github_cli.parse(["issue", "close", "7", "-R", "acme/widgets"]) {
    @github_cli.Business(value) => value
    _ => fail("expected issue invocation")
  }
  let close = @native.execute_github_business(
    close_options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(close.exit_code(), 0)
  guard seen[0].2 is Some(close_body) else { fail("close body missing") }
  assert_true(@utf8.decode(close_body).contains("closed"))

  let ready_options = match
    @github_cli.parse(["pr", "ready", "8", "-R", "acme/widgets"]) {
    @github_cli.Business(value) => value
    _ => fail("expected pull request invocation")
  }
  let ready = @native.execute_github_business(
    ready_options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(ready.exit_code(), 0)
  guard seen[1].2 is Some(ready_body) else { fail("ready body missing") }
  assert_true(@utf8.decode(ready_body).contains("draft"))
  assert_true(@utf8.decode(ready_body).contains("false"))

  let rename_options = match
    @github_cli.parse([
      "repo", "rename", "-R", "acme/widgets", "--new-name", "widgets-next",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected repository invocation")
  }
  let rename = @native.execute_github_business(
    rename_options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(rename.exit_code(), 0)
  guard seen[2].2 is Some(rename_body) else { fail("rename body missing") }
  assert_true(@utf8.decode(rename_body).contains("widgets-next"))
}

///|
async test "search prs adds an is:pr qualifier" {
  let mut query : Array[(String, String)] = []
  let transport = @github.Transport::new(send=request => {
    query = request.query()
    Ok(@github.RawResponse::new(status=200, body=b"{\"items\":[]}"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let options = match @github_cli.parse(["search", "prs", "regression"]) {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 0)
  guard query.get(0) is Some((key, value)) else { fail("query missing") }
  assert_eq(key, "q")
  assert_true(value.contains("is:pr"))
}

///|
/// Collection endpoints return an object envelope over the array that gh
/// exposes to `--json` projections.  Keep this behavior aligned for runs,
/// workflows, and search results.
async test "business json projection unwraps GitHub collection envelopes" {
  let transport = @github.Transport::new(send=request => {
    let body = match request.path() {
      "/repos/acme/widgets/actions/runs" =>
        b"{\"total_count\":1,\"workflow_runs\":[{\"id\":42,\"workflow_id\":7,\"status\":\"completed\",\"conclusion\":\"success\",\"name\":\"CI\"}]}"
      "/repos/acme/widgets/actions/workflows" =>
        b"{\"total_count\":1,\"workflows\":[{\"id\":7,\"name\":\"CI\",\"state\":\"active\"}]}"
      "/search/issues" =>
        b"{\"total_count\":1,\"items\":[{\"number\":9,\"title\":\"Bug\",\"state\":\"open\"}]}"
      "/search/repositories" =>
        b"{\"total_count\":1,\"items\":[{\"name\":\"widgets\",\"full_name\":\"acme/widgets\",\"private\":false}]}"
      _ => fail("unexpected collection path")
    }
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
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  let run_options = match
    @github_cli.parse([
      "run", "list", "-R", "acme/widgets", "--json", "databaseId,workflowDatabaseId,status,conclusion,name",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected run invocation")
  }
  let run_output = @native.execute_github_business(
    run_options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(run_output.exit_code(), 0)
  assert_eq(@json.parse(run_output.stdout()), [
    {
      "databaseId": 42,
      "workflowDatabaseId": 7,
      "status": "completed",
      "conclusion": "success",
      "name": "CI",
    },
  ])
  let workflow_options = match
    @github_cli.parse([
      "workflow", "list", "-R", "acme/widgets", "--json", "id,name,state",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected workflow invocation")
  }
  let workflow_output = @native.execute_github_business(
    workflow_options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(workflow_output.exit_code(), 0)
  assert_eq(@json.parse(workflow_output.stdout()), [
    { "id": 7, "name": "CI", "state": "active" },
  ])
  let search_options = match
    @github_cli.parse([
      "search", "issues", "bug", "--json", "number,title,state",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected search invocation")
  }
  let search_output = @native.execute_github_business(
    search_options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(search_output.exit_code(), 0)
  assert_eq(@json.parse(search_output.stdout()), [
    { "number": 9, "title": "Bug", "state": "open" },
  ])
  let repository_search_options = match
    @github_cli.parse(["search", "repos", "widgets", "--json", "fullName"]) {
    @github_cli.Business(value) => value
    _ => fail("expected repository search invocation")
  }
  let repository_search_output = @native.execute_github_business(
    repository_search_options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(repository_search_output.exit_code(), 0)
  assert_eq(@json.parse(repository_search_output.stdout()), [
    { "fullName": "acme/widgets" },
  ])
}

///|
/// Verify the business runner through the real Native HTTP adapter and a
/// loopback fixture server. This catches URL assembly and wire-level behavior
/// that an in-memory transport cannot observe.
async test "business command loopback fixture serves repo status and release" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      let first = server.accept()
      let (conn, _) = first
      defer conn.close()
      let request = conn.read_request()
      assert_eq(request.meth, @http.Get)
      assert_eq(request.path, "/repos/acme/widgets")
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
      })
      conn..write("{\"name\":\"widgets\"}\n").end_response()

      let second = server.accept()
      let (conn, _) = second
      defer conn.close()
      let request = conn.read_request()
      assert_eq(request.meth, @http.Get)
      assert_eq(request.path, "/notifications?all=true")
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
      })
      conn..write("[]\n").end_response()

      let third = server.accept()
      let (conn, _) = third
      defer conn.close()
      let request = conn.read_request()
      assert_eq(request.meth, @http.Get)
      assert_eq(request.path, "/repos/acme/widgets/releases/tags/v1%2F2026")
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
      })
      conn..write("{\"tag_name\":\"v1/2026\"}\n").end_response()
    }
    let base_url = "http://127.0.0.1:\{server.addr.port()}"
    let client = match @native.github_client(base_url~) {
      Ok(value) => value
      Err(_) => fail("loopback GitHub client setup failed")
    }
    let repository = match
      @github_cli.RepositoryContext::parse("acme/widgets") {
      Ok(value) => value
      Err(_) => fail("repository parse failed")
    }
    let repo_options = match
      @github_cli.parse(["repo", "view", "-R", "acme/widgets"]) {
      @github_cli.Business(value) => value
      _ => fail("expected repo invocation")
    }
    let repo_output = @native.execute_github_business(
      repo_options,
      client~,
      base_url~,
      repository~,
    )
    assert_eq(repo_output.exit_code(), 0)
    assert_true(repo_output.stdout().contains("widgets"))

    let status_options = match @github_cli.parse(["status", "--all"]) {
      @github_cli.Business(value) => value
      _ => fail("expected status invocation")
    }
    let status_output = @native.execute_github_business(
      status_options,
      client~,
      base_url~,
    )
    assert_eq(status_output.exit_code(), 0)

    let release_options = match
      @github_cli.parse(["release", "view", "v1/2026", "-R", "acme/widgets"]) {
      @github_cli.Business(value) => value
      _ => fail("expected release invocation")
    }
    let release_output = @native.execute_github_business(
      release_options,
      client~,
      base_url~,
      repository~,
    )
    assert_eq(release_output.exit_code(), 0)
    assert_true(release_output.stdout().contains("v1/2026"))
  }
}

///|
/// Projects V2 and Discussions are served by GitHub's GraphQL endpoint.  The
/// fixture checks the wire request and returns a small GraphQL envelope so the
/// business renderer also proves that `data.*.nodes` is exposed as a CLI
/// collection.
async test "projects and discussions business commands use GraphQL" {
  let seen : Array[(String, String, String)] = []
  let transport = @github.Transport::new(send=request => {
    let body = match request.body() {
      Some(value) =>
        @utf8.decode(value) catch {
          _ => fail("GraphQL body was not UTF-8")
        }
      None => fail("GraphQL request body was absent")
    }
    seen.push((request.verb(), request.path(), body))
    if body.contains("ProjectList") {
      Ok(
        @github.RawResponse::new(
          status=200,
          body=b"{\"data\":{\"user\":{\"projectsV2\":{\"nodes\":[{\"number\":7,\"title\":\"Roadmap\"}]}}}}",
        ),
      )
    } else {
      Ok(
        @github.RawResponse::new(
          status=200,
          body=b"{\"data\":{\"repository\":{\"discussion\":{\"number\":3,\"title\":\"Welcome\"}}}}",
        ),
      )
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
  let project_options = match
    @github_cli.parse([
      "project", "list", "--owner", "octocat", "--json", "number,title",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected project invocation")
  }
  let project_output = @native.execute_github_business(
    project_options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(project_output.exit_code(), 0)
  assert_eq(@json.parse(project_output.stdout()), [
    { "number": 7, "title": "Roadmap" },
  ])
  let discussion_options = match
    @github_cli.parse([
      "discussion", "view", "3", "-R", "acme/widgets", "--json", "number,title",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected discussion invocation")
  }
  let discussion_output = @native.execute_github_business(
    discussion_options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(discussion_output.exit_code(), 0)
  assert_eq(@json.parse(discussion_output.stdout()), {
    "number": 3,
    "title": "Welcome",
  })
  assert_eq(seen.length(), 2)
  assert_eq(seen[0].0, "POST")
  assert_eq(seen[0].1, "/graphql")
  assert_true(seen[0].2.contains("\"operationName\":\"ProjectList\""))
  assert_true(seen[0].2.contains("\"login\":\"octocat\""))
  assert_eq(seen[1].0, "POST")
  assert_eq(seen[1].1, "/graphql")
  assert_true(seen[1].2.contains("\"operationName\":\"DiscussionView\""))
  assert_true(seen[1].2.contains("\"owner\":\"acme\""))
  assert_true(seen[1].2.contains("\"name\":\"widgets\""))
}

///|
/// GraphQL business collections use cursor pagination when a requested limit
/// exceeds GitHub's 100-node connection page.  The query contains several
/// Project owner fallbacks, so the fixture also proves that the selected
/// viewer connection's cursor is used instead of guessing across pageInfo
/// objects.
async test "project GraphQL list follows cursor pagination" {
  let seen : Array[String] = []
  let transport = @github.Transport::new(send=request => {
    let body = match request.body() {
      Some(value) =>
        @utf8.decode(value) catch {
          _ => fail("body was not UTF-8")
        }
      None => fail("GraphQL body was absent")
    }
    seen.push(body)
    if body.contains("\"after\":\"cursor-1\"") {
      Ok(
        @github.RawResponse::new(
          status=200,
          body=b"{\"data\":{\"viewer\":{\"projectsV2\":{\"nodes\":[{\"number\":2,\"title\":\"Second\"}],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":\"cursor-2\"}},\"user\":null,\"organization\":null}}}",
        ),
      )
    } else {
      Ok(
        @github.RawResponse::new(
          status=200,
          body=b"{\"data\":{\"viewer\":{\"projectsV2\":{\"nodes\":[{\"number\":1,\"title\":\"First\"}],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"cursor-1\"}},\"user\":null,\"organization\":null}}}",
        ),
      )
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
      "project", "list", "--limit", "101", "--json", "number,title",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected project invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(@json.parse(output.stdout()), [
    { "number": 1, "title": "First" },
    { "number": 2, "title": "Second" },
  ])
  assert_eq(seen.length(), 2)
  assert_true(seen[0].contains("\"after\":null"))
  assert_true(seen[1].contains("\"after\":\"cursor-1\""))
}

///|
/// Issue deletion uses the GraphQL node id mutation because GitHub's REST API
/// intentionally returns 404 for DELETE /issues/{number}.
async test "issue delete resolves node id and sends GraphQL mutation" {
  let seen : Array[String] = []
  let transport = @github.Transport::new(send=request => {
    let body = match request.body() {
      Some(value) =>
        @utf8.decode(value) catch {
          _ => fail("body was not UTF-8")
        }
      None => fail("GraphQL body was absent")
    }
    seen.push(body)
    if body.contains("IssueDeleteLookup") {
      Ok(
        @github.RawResponse::new(
          status=200,
          body=b"{\"data\":{\"repository\":{\"issue\":{\"id\":\"I_kwDOfixture\"}}}}",
        ),
      )
    } else {
      Ok(
        @github.RawResponse::new(
          status=200,
          body=b"{\"data\":{\"deleteIssue\":{\"clientMutationId\":null}}}",
        ),
      )
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
    @github_cli.parse(["issue", "delete", "4", "-R", "acme/widgets", "--yes"]) {
    @github_cli.Business(value) => value
    _ => fail("expected issue invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 0)
  assert_true(output.stdout().is_empty())
  assert_eq(seen.length(), 2)
  assert_true(seen[0].contains("\"operationName\":\"IssueDeleteLookup\""))
  assert_true(seen[0].contains("\"number\":4"))
  assert_true(seen[1].contains("\"operationName\":\"IssueDelete\""))
  assert_true(seen[1].contains("\"issueId\":\"I_kwDOfixture\""))
}

///|
/// A successful HTTP response can still carry GraphQL errors.  Surface the
/// provider message on stderr while keeping the command failure exit code.
async test "business GraphQL errors preserve the first provider message" {
  let transport = @github.Transport::new(send=_request => {
    Ok(
      @github.RawResponse::new(
        status=200,
        body=b"{\"errors\":[{\"message\":\"Field 'projectV2' requires owner access\"}],\"data\":null}",
      ),
    )
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
      "project", "list", "--owner", "octocat", "--json", "number,title",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected project invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 1)
  assert_true(output.stdout().is_empty())
  assert_true(
    output.stderr().contains("Field 'projectV2' requires owner access"),
  )
}

///|
/// The native HTTP adapter must select the GraphQL URL as well.  This
/// loopback fixture catches accidental fallback to `/repos/.../discussions`.
async test "discussion list loopback fixture posts GraphQL envelope" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      let accepted = server.accept()
      let (conn, _) = accepted
      defer conn.close()
      let request = conn.read_request()
      assert_eq(request.meth, @http.Post)
      assert_eq(request.path, "/graphql")
      let body = conn.read_all().text()
      assert_true(body.contains("\"operationName\":\"DiscussionList\""))
      assert_true(body.contains("\"owner\":\"acme\""))
      assert_true(body.contains("\"name\":\"widgets\""))
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
      })
      conn
      ..write(
        "{\"data\":{\"repository\":{\"discussions\":{\"nodes\":[{\"number\":1,\"title\":\"Hello\"}]}}}}",
      )
      .end_response()
    }
    let base_url = "http://127.0.0.1:\{server.addr.port()}"
    let client = match @native.github_client(base_url~) {
      Ok(value) => value
      Err(_) => fail("loopback GitHub client setup failed")
    }
    let repository = match
      @github_cli.RepositoryContext::parse("acme/widgets") {
      Ok(value) => value
      Err(_) => fail("repository parse failed")
    }
    let options = match
      @github_cli.parse([
        "discussion", "list", "-R", "acme/widgets", "--json", "number,title",
      ]) {
      @github_cli.Business(value) => value
      _ => fail("expected discussion invocation")
    }
    let output = @native.execute_github_business(
      options,
      client~,
      base_url~,
      repository~,
    )
    assert_eq(output.exit_code(), 0)
    assert_eq(@json.parse(output.stdout()), [{ "number": 1, "title": "Hello" }])
  }
}

///|
async test "business path arguments are encoded as one REST segment" {
  let mut seen_path = ""
  let transport = @github.Transport::new(send=request => {
    seen_path = request.path()
    Ok(@github.RawResponse::new(status=200, body=b"{}"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let invocation = @github_cli.parse(["gist", "view", "a?b#c d"])
  let options = match invocation {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen_path, "/gists/a%3Fb%23c%20d")
}

///|
async test "business parser rejects unknown resource subcommands" {
  let transport = @github.Transport::new(send=_ => {
    fail("unknown subcommand must not reach transport")
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  for
    args in [
      ["search", "unknown", "term"],
      ["workflow", "unknown", "-R", "acme/widgets"],
      ["project", "unknown"],
      ["licenses", "unknown"],
    ] {
    let options = match @github_cli.parse(args) {
      @github_cli.Business(value) => value
      _ => fail("expected business invocation")
    }
    let output = @native.execute_github_business(
      options,
      client~,
      base_url="https://api.github.example",
    )
    assert_eq(output.exit_code(), 1)
    assert_true(output.stderr().contains("unsupported"))
  }
}

///|
async test "business parser rejects unknown long flags" {
  let transport = @github.Transport::new(send=_ => {
    fail("unknown flag must not reach transport")
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
    @github_cli.parse(["issue", "list", "-R", "acme/widgets", "--sttae", "open"]) {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 1)
  assert_true(output.stderr().contains("unknown flag: --sttae"))
}

///|
async test "business JSON rejects an unknown field before transport" {
  let transport = @github.Transport::new(send=_ => {
    fail("unknown JSON field must not reach transport")
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
      "issue", "list", "-R", "acme/widgets", "--json", "definitelyUnknownField",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 1)
  assert_true(output.stderr().contains("unknown JSON field"))
}

///|
/// Search qualifiers belong in the `q` expression (GitHub's search API),
/// while pagination remains a regular query parameter.
async test "search repository qualifier and code filters are encoded in q" {
  let mut seen_query : Array[(String, String)] = []
  let transport = @github.Transport::new(send=request => {
    seen_query = request.query()
    Ok(@github.RawResponse::new(status=200, body=b"{\"items\":[]}"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let invocation = @github_cli.parse([
    "search", "code", "token", "-R", "acme/widgets", "--filename", "main.mbt", "--language",
    "moonbit", "--limit", "5",
  ])
  let options = match invocation {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 0)
  assert_true(
    seen_query.contains(
      ("q", "token repo:acme/widgets filename:main.mbt language:moonbit"),
    ),
  )
  assert_true(seen_query.contains(("per_page", "5")))
}

///|
async test "pull request diff uses diff media type and checks accept ref" {
  let seen_path : Array[String] = []
  let seen_headers : Array[Array[(String, String)]] = []
  let transport = @github.Transport::new(send=request => {
    seen_path.push(request.path())
    seen_headers.push(request.headers())
    Ok(@github.RawResponse::new(status=200, body=b"{}"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  for
    args in [
      ["pr", "diff", "7", "-R", "acme/widgets"],
      ["pr", "checks", "7", "-R", "acme/widgets", "--ref", "deadbeef"],
    ] {
    let options = match @github_cli.parse(args) {
      @github_cli.Business(value) => value
      _ => fail("expected business invocation")
    }
    let output = @native.execute_github_business(
      options,
      client~,
      base_url="https://api.github.example",
      repository~,
    )
    assert_eq(output.exit_code(), 0)
  }
  assert_eq(seen_path[0], "/repos/acme/widgets/pulls/7")
  assert_true(
    seen_headers[0].contains(("Accept", "application/vnd.github.diff")),
  )
  assert_eq(seen_path[1], "/repos/acme/widgets/commits/deadbeef/check-runs")
}

///|
async test "issue locks carry lock reason and run log routes preserve bytes" {
  let seen : Array[(String, String, Bytes?)] = []
  let transport = @github.Transport::new(send=request => {
    seen.push((request.verb(), request.path(), request.body()))
    Ok(@github.RawResponse::new(status=200, body=b"binary-log"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  let lock_options = match
    @github_cli.parse([
      "issue", "lock", "12", "-R", "acme/widgets", "--reason", "resolved",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let lock_output = @native.execute_github_business(
    lock_options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(lock_output.exit_code(), 0)
  guard seen[0].2 is Some(body) else { fail("lock body was absent") }
  let text = @utf8.decode(body) catch { _ => fail("lock body was not UTF-8") }
  assert_true(text.contains("lock_reason"))
  assert_true(text.contains("resolved"))

  let run_options = match
    @github_cli.parse(["run", "view", "99", "-R", "acme/widgets", "--log"]) {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let run_output = @native.execute_github_business(
    run_options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(run_output.exit_code(), 0)
  assert_eq(seen[1].1, "/repos/acme/widgets/actions/runs/99/logs")
  assert_eq(run_output.stdout_bytes(), b"binary-log")
}

///|
async test "issue and pull request comments use issue comment endpoint" {
  let seen : Array[(String, String, Bytes?)] = []
  let transport = @github.Transport::new(send=request => {
    seen.push((request.verb(), request.path(), request.body()))
    Ok(@github.RawResponse::new(status=201, body=b"{}"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  for
    args in [
      ["issue", "comment", "4", "-R", "acme/widgets", "--body", "hello"],
      ["pr", "comment", "8", "-R", "acme/widgets", "--body", "review"],
    ] {
    let options = match @github_cli.parse(args) {
      @github_cli.Business(value) => value
      _ => fail("expected business invocation")
    }
    let output = @native.execute_github_business(
      options,
      client~,
      base_url="https://api.github.example",
      repository~,
    )
    assert_eq(output.exit_code(), 0)
  }
  assert_eq(seen[0].0, "POST")
  assert_eq(seen[0].1, "/repos/acme/widgets/issues/4/comments")
  assert_eq(seen[1].0, "POST")
  assert_eq(seen[1].1, "/repos/acme/widgets/issues/8/comments")
}

///|
async test "nested business command without arguments prints help before auth" {
  let output = @native.run_github(["issue"])
  assert_eq(output.exit_code(), 0)
  assert_true(output.stdout().contains("Manage GitHub issues."))
  assert_eq(output.stderr(), "")
}

///|
async test "repo clone validates repository and clone options before git" {
  let invalid_repo = @native.run_github(["repo", "clone", "not-a-repository"])
  assert_eq(invalid_repo.exit_code(), 1)
  assert_true(invalid_repo.stderr().contains("OWNER/REPO"))
  let invalid_depth = @native.run_github([
    "repo", "clone", "acme/widgets", "--depth", "not-a-number",
  ])
  assert_eq(invalid_depth.exit_code(), 1)
  assert_true(invalid_depth.stderr().contains("depth"))
}

///|
/// Release downloads resolve metadata first, then preserve the binary asset
/// response when writing the selected file to the requested directory.
async test "release download fixture writes selected binary asset" {
  let directory = @fs.tmpdir(prefix="gh-release-download-")
  defer @fs.rmdir(directory, recursive=true)
  let seen : Array[(String, String)] = []
  let transport = @github.Transport::new(send=request => {
    seen.push((request.verb(), request.path()))
    if request.path().has_suffix("/releases/tags/v1") {
      Ok(
        @github.RawResponse::new(
          status=200,
          body=b"{\"id\":42,\"assets\":[{\"id\":7,\"name\":\"tool.tar.gz\"},{\"id\":8,\"name\":\"tool.txt\"}]}",
        ),
      )
    } else {
      Ok(@github.RawResponse::new(status=200, body=b"binary\x00asset"))
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
      "release", "download", "v1", "-R", "acme/widgets", "--dir", directory, "--pattern",
      "*.tar.gz",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected release download invocation")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen.length(), 2)
  assert_eq(seen[1].1, "/repos/acme/widgets/releases/assets/7")
  assert_true(@fs.exists(directory + "/tool.tar.gz"))
  assert_eq(
    @fs.read_file(directory + "/tool.tar.gz").binary(),
    b"binary\x00asset",
  )
  assert_false(@fs.exists(directory + "/tool.txt"))
}

///|
async test "release upload fixture sends binary assets to release id" {
  let directory = @fs.tmpdir(prefix="gh-release-upload-")
  defer @fs.rmdir(directory, recursive=true)
  let source = directory + "/tool.bin"
  @fs.write_file(source, b"upload\x00bytes")
  let seen : Array[(String, String, Array[(String, String)], Bytes?, String)] = []
  let transport = @github.Transport::new(send=request => {
    seen.push(
      (
        request.verb(),
        request.path(),
        request.query(),
        request.body(),
        request.url(),
      ),
    )
    if request.verb() == "GET" {
      Ok(
        @github.RawResponse::new(
          status=200,
          body=b"{\"id\":42,\"upload_url\":\"https://uploads.github.example/repos/acme/widgets/releases/42/assets{?name,label}\"}",
        ),
      )
    } else {
      Ok(@github.RawResponse::new(status=201, body=b"{}"))
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
    @github_cli.parse(["release", "upload", "v1", source, "-R", "acme/widgets"]) {
    @github_cli.Business(value) => value
    _ => fail("expected release upload invocation")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen.length(), 2)
  assert_eq(seen[1].0, "POST")
  assert_eq(seen[1].1, "/repos/acme/widgets/releases/42/assets")
  assert_true(seen[1].2.contains(("name", "tool.bin")))
  assert_eq(
    seen[1].4,
    "https://uploads.github.example/repos/acme/widgets/releases/42/assets?name=tool.bin",
  )
  guard seen[1].3 is Some(body) else { fail("upload body missing") }
  assert_eq(body, b"upload\x00bytes")
}

///|
async test "run watch fixture polls until completion and honors exit status" {
  let mut calls = 0
  let transport = @github.Transport::new(send=_request => {
    calls += 1
    if calls == 1 {
      Ok(
        @github.RawResponse::new(
          status=200,
          body=b"{\"status\":\"in_progress\",\"conclusion\":null}",
        ),
      )
    } else {
      Ok(
        @github.RawResponse::new(
          status=200,
          body=b"{\"status\":\"completed\",\"conclusion\":\"failure\"}",
        ),
      )
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
      "run", "watch", "99", "-R", "acme/widgets", "--interval", "0", "--exit-status",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected run watch invocation")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(calls, 2)
  assert_eq(output.exit_code(), 1)
  assert_true(output.stdout().contains("completed"))
}

///|
/// Newer v2.102.0 resource subcommands use the same raw request seam as the
/// original command set. Keep a compact matrix here so endpoint regressions
/// are caught without credentials or a remote GitHub account.
async test "extended core commands map to GitHub REST endpoints" {
  let seen : Array[(String, String, Bytes?)] = []
  let transport = @github.Transport::new(send=request => {
    seen.push((request.verb(), request.path(), request.body()))
    Ok(@github.RawResponse::new(status=200, body=b"{}"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("client setup failed")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  let cases : Array[(Array[String], String, String)] = [
    (["repo", "archive", "-R", "acme/widgets"], "PATCH", "/repos/acme/widgets"),
    (
      ["repo", "deploy-key", "list", "-R", "acme/widgets"],
      "GET",
      "/repos/acme/widgets/keys",
    ),
    (
      ["repo", "read-file", "README.md", "-R", "acme/widgets"],
      "GET",
      "/repos/acme/widgets/contents/README.md",
    ),
    (
      ["issue", "pin", "7", "-R", "acme/widgets"],
      "PUT",
      "/repos/acme/widgets/issues/7/pin",
    ),
    (
      ["pr", "update-branch", "7", "-R", "acme/widgets"],
      "PUT",
      "/repos/acme/widgets/pulls/7/update-branch",
    ),
    (
      ["pr", "revert", "7", "-R", "acme/widgets"],
      "POST",
      "/repos/acme/widgets/pulls/7/revert",
    ),
  ]
  for (args, expected_method, expected_path) in cases {
    let options = match @github_cli.parse(args) {
      @github_cli.Business(value) => value
      _ => fail("expected business invocation")
    }
    let output = @native.execute_github_business(
      options,
      client~,
      base_url="https://api.github.example",
      repository~,
    )
    assert_eq(output.exit_code(), 0)
    let (verb, path, _) = seen[seen.length() - 1]
    assert_eq(verb, expected_method)
    assert_eq(path, expected_path)
  }
}

///|
/// Typed issue/pr output uses GraphQL enum spelling even though the REST
/// collection returns lower-case state values. Search output deliberately
/// remains lower-case and is covered by the live search fixture.
async test "issue JSON state is normalized to GraphQL enum spelling" {
  let transport = @github.Transport::new(send=_request => {
    Ok(
      @github.RawResponse::new(
        status=200,
        body=b"[{\"number\":7,\"state\":\"closed\",\"title\":\"old\"}]",
      ),
    )
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("client setup failed")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  let options = match
    @github_cli.parse([
      "issue", "list", "-R", "acme/widgets", "--json", "number,state",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stdout(), "[{\"number\":7,\"state\":\"CLOSED\"}]\n")
}

///|
async test "merged pull request JSON state uses MERGED enum" {
  let transport = @github.Transport::new(send=_request => {
    Ok(
      @github.RawResponse::new(
        status=200,
        body=b"[{\"number\":8,\"state\":\"closed\",\"merged_at\":\"2026-10-17T00:00:00Z\"}]",
      ),
    )
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("client setup failed")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  let options = match
    @github_cli.parse([
      "pr", "list", "-R", "acme/widgets", "--json", "number,state",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
    repository~,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stdout(), "[{\"number\":8,\"state\":\"MERGED\"}]\n")
}

///|
/// `gh repo view [OWNER/REPO]` uses the positional repository before any
/// inferred local repository. This also proves no git checkout is required.
async test "repo view positional repository overrides injected context" {
  let mut seen_path = ""
  let transport = @github.Transport::new(send=request => {
    seen_path = request.path()
    Ok(
      @github.RawResponse::new(
        status=200,
        body=b"{\"name\":\"target\",\"full_name\":\"other/target\"}",
      ),
    )
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("client setup failed")
  }
  let local_context = match
    @github_cli.RepositoryContext::parse("local/current") {
    Ok(value) => value
    Err(_) => fail("local repository parse failed")
  }
  let options = match
    @github_cli.parse(["repo", "view", "other/target", "--json", "name"]) {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
    repository=local_context,
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen_path, "/repos/other/target")
  assert_eq(output.stdout(), "{\"name\":\"target\"}\n")
  let without_context = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(without_context.exit_code(), 0)
  assert_eq(seen_path, "/repos/other/target")
  assert_eq(without_context.stdout(), output.stdout())
}

///|
/// The issue close reason is sent under REST's `state_reason` key.
async test "issue close reason maps to state_reason" {
  let mut seen_body : Bytes? = None
  let transport = @github.Transport::new(send=request => {
    seen_body = request.body()
    Ok(@github.RawResponse::new(status=200, body=b"{}"))
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("client setup failed")
  }
  let options = match
    @github_cli.parse([
      "issue", "close", "7", "-R", "acme/widgets", "--reason", "not planned",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("repository parse failed")
  }
  ignore(
    @native.execute_github_business(
      options,
      client~,
      base_url="https://api.github.example",
      repository~,
    ),
  )
  guard seen_body is Some(body) else { fail("request body was absent") }
  let text = @utf8.decode(body) catch { _ => fail("body was not UTF-8") }
  assert_true(text.contains("\"state\":\"closed\""))
  assert_true(text.contains("\"state_reason\":\"not_planned\""))
}
