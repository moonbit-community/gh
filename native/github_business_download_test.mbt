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
