///|
async test "release download streams twenty MiB through native HTTP and publishes exact file" {
  let directory = @fs.tmpdir(prefix="gh-release-large-")
  defer @fs.rmdir(directory, recursive=true)
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      for part in 0..<3 {
        let (conn, _) = server.accept()
        defer conn.close()
        let request = conn.read_request()
        assert_eq(request.meth, @http.Get)
        match part {
          0 => {
            assert_eq(request.path, "/repos/acme/widgets/releases/tags/v1")
            conn.send_response(200, "OK", extra_headers={
              "Content-Type": "application/json",
            })
            conn
            ..write(
              b"{\"id\":42,\"assets\":[{\"id\":7,\"name\":\"tool.bin\"}]}",
            )
            .end_response()
          }
          1 => {
            assert_eq(request.path, "/repos/acme/widgets/releases/assets/7")
            conn.send_response(302, "Found", extra_headers={
              "Location": "/asset",
            })
            conn.end_response()
          }
          _ => {
            assert_eq(request.path, "/asset")
            conn.send_response(200, "OK")
            let chunk = Bytes::make(65536, b'\xa5')
            for _ in 0..<320 {
              conn.write(chunk)
            }
            conn.end_response()
          }
        }
      }
    }
    let base_url = "http://127.0.0.1:\{server.addr.port()}"
    guard @native.github_client(base_url~, max_response_bytes=1024)
      is Ok(client) else {
      fail("invalid native fixture client")
    }
    guard @github_cli.RepositoryContext::parse("acme/widgets") is Ok(repository) else {
      fail("invalid fixture repository")
    }
    guard @github_cli.parse([
        "release", "download", "v1", "-R", "acme/widgets", "--dir", directory,
      ])
      is @github_cli.Business(options) else {
      fail("invalid fixture invocation")
    }
    let output = @native.execute_github_business(
      options,
      client~,
      repository~,
      base_url~,
    )
    assert_eq(output.exit_code(), 0)
    assert_eq(@fs.readdir(directory), ["tool.bin"])
    let file = @fs.open(directory + "/tool.bin", mode=ReadOnly)
    defer file.close()
    assert_eq(file.size(), 20971520L)
    let mut count = 0L
    while file.read_some(max_len=65536) is Some(bytes) {
      assert_true(bytes.iter().all(byte => byte == b'\xa5'))
      count += bytes.length().to_int64()
    }
    assert_eq(count, 20971520L)
  }
}

///|
async test "release download cancellation exits two without writing asset" {
  let directory = @fs.tmpdir(prefix="gh-download-cancel-")
  defer @fs.rmdir(directory, recursive=true)
  let mut calls = 0
  let transport = @github.Transport::new(send=request => {
    calls += 1
    if calls == 1 {
      assert_eq(request.path(), "/repos/acme/widgets/releases/tags/v1")
      Ok(
        @github.RawResponse::new(
          status=200,
          body=b"{\"id\":42,\"assets\":[{\"id\":7,\"name\":\"tool.bin\"}]}",
        ),
      )
    } else {
      assert_eq(request.path(), "/repos/acme/widgets/releases/assets/7")
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
  let repository = match @github_cli.RepositoryContext::parse("acme/widgets") {
    Ok(value) => value
    Err(_) => fail("fixture repository invalid")
  }
  let options = match
    @github_cli.parse([
      "release", "download", "v1", "-R", "acme/widgets", "--dir", directory,
    ]) {
    @github_cli.Business(value) => value
    _ => fail("fixture invocation invalid")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    repository~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 2)
  assert_eq(output.stdout(), "")
  assert_eq(calls, 2)
  assert_false(@fs.exists(directory + "/tool.bin"))
}
