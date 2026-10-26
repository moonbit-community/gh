///|
/// Exercise `gh api --paginate --slurp` against a real loopback HTTP server.
/// The fixture deliberately uses two TCP connections, matching the raw
/// transport contract (one request per connection) and preserving Link
/// headers as received from the wire.
async test "github api loopback REST pagination preserves pages and query" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      let first = server.accept()
      let (conn, _) = first
      defer conn.close()
      let request = conn.read_request()
      assert_eq(request.meth, @http.Get)
      assert_eq(request.path, "/fixture?page=1")
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
        "Link": "<http://127.0.0.1:\{server.addr.port()}/fixture?page=2>; rel=\"next\"",
      })
      conn..write("[{\"id\":1}]\n").end_response()

      let second = server.accept()
      let (conn, _) = second
      defer conn.close()
      let request = conn.read_request()
      assert_eq(request.meth, @http.Get)
      assert_eq(request.path, "/fixture?page=2")
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
      })
      conn..write("[{\"id\":2}]\n").end_response()
    }
    let base_url = "http://127.0.0.1:\{server.addr.port()}"
    let client = match @native.github_client(base_url~) {
      Ok(value) => value
      Err(_) => fail("loopback GitHub client setup failed")
    }
    let options = match
      @github_cli.parse(["api", "fixture?page=1", "--paginate", "--slurp"]) {
      @github_cli.Api(value) => value
      _ => fail("expected API options")
    }
    let output = @native.execute_github_api(options, client~, base_url~)
    assert_eq(output.exit_code(), 0)
    assert_eq(output.stderr(), "")
    assert_eq(output.stdout(), "[[{\"id\":1}],[{\"id\":2}]]\n")
  }
}

///|
/// GraphQL pagination updates the `endCursor` variable in the request body,
/// while preserving the raw JSON response pages for `--slurp` output.
async test "github api loopback GraphQL pagination updates cursor" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      let first = server.accept()
      let (conn, _) = first
      defer conn.close()
      let request = conn.read_request()
      assert_eq(request.meth, @http.Post)
      let body = conn.read_all().text()
      assert_true(body.contains("\"query\""))
      assert_false(body.contains("\"endCursor\":\"cursor-1\""))
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
      })
      conn
      ..write(
        "{\"data\":{\"repository\":{\"nodes\":[{\"id\":1}],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"cursor-1\"}}}}",
      )
      .end_response()

      let second = server.accept()
      let (conn, _) = second
      defer conn.close()
      let request = conn.read_request()
      assert_eq(request.meth, @http.Post)
      let body = conn.read_all().text()
      assert_true(body.contains("\"endCursor\":\"cursor-1\""))
      conn.send_response(200, "OK", extra_headers={
        "Content-Type": "application/json",
      })
      conn
      ..write(
        "{\"data\":{\"repository\":{\"nodes\":[{\"id\":2}],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":\"cursor-2\"}}}}",
      )
      .end_response()
    }
    let base_url = "http://127.0.0.1:\{server.addr.port()}"
    let client = match @native.github_client(base_url~) {
      Ok(value) => value
      Err(_) => fail("loopback GitHub client setup failed")
    }
    let options = match
      @github_cli.parse([
        "api", "graphql", "--paginate", "--slurp", "-F", "query=query { repository { nodes { id } pageInfo { hasNextPage endCursor } } }",
      ]) {
      @github_cli.Api(value) => value
      _ => fail("expected GraphQL API options")
    }
    let output = @native.execute_github_api(options, client~, base_url~)
    assert_eq(output.exit_code(), 0)
    assert_eq(output.stderr(), "")
    assert_true(output.stdout().contains("\"id\":1"))
    assert_true(output.stdout().contains("\"id\":2"))
  }
}

///|
async test "github api cache reuses a successful response without a second request" {
  let directory = @fs.tmpdir(prefix="gh-api-cache-")
  defer @fs.rmdir(directory, recursive=true)
  let previous_cache = @env.get_env_var("XDG_CACHE_HOME")
  @env.set_env_var("XDG_CACHE_HOME", directory)
  defer (match previous_cache {
    Some(value) => @env.set_env_var("XDG_CACHE_HOME", value)
    None => @env.unset_env_var("XDG_CACHE_HOME")
  })
  let calls = Ref(0)
  let transport = @github.Transport::new(send=_request => {
    calls.val += 1
    Ok(
      @github.RawResponse::new(
        status=200,
        headers=[("Content-Type", "application/json")],
        body=@utf8.encode("{\"cached\":true}"),
      ),
    )
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.com"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("client setup failed")
  }
  let options = match @github_cli.parse(["api", "fixture", "--cache", "1h"]) {
    @github_cli.Api(value) => value
    _ => fail("expected API options")
  }
  let first = @native.execute_github_api(
    options,
    client~,
    base_url="https://api.github.com",
  )
  assert_eq(first.exit_code(), 0)
  let second = @native.execute_github_api(
    options,
    client~,
    base_url="https://api.github.com",
  )
  assert_eq(second.exit_code(), 0)
  assert_eq(second.stdout(), first.stdout())
  assert_eq(calls.val, 1)
  let cleared = @native.github_config_command(
    ["clear-cache"],
    cache_dir=directory + "/gh",
  )
  assert_eq(cleared.exit_code(), 0)
  assert_false(@fs.exists(directory + "/gh"))
  let third = @native.execute_github_api(
    options,
    client~,
    base_url="https://api.github.com",
  )
  assert_eq(third.exit_code(), 0)
  assert_eq(calls.val, 2)
}
