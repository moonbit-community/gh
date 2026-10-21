///|
async test "cache bulk deletion rejects foreign pages and duplicate identities before writing" {
  for
    (link, body) in [
      (
        "<https://outside.example/caches>; rel=\"next\"", b"{\"actions_caches\":[{\"id\":12}]}",
      ),
      (
        "<http://api.github.localhost/repos/other/project/actions/caches?page=2>; rel=\"next\"",
        b"{\"actions_caches\":[{\"id\":12}]}",
      ),
      (
        "<http://api.github.localhost/repos/acme/widgets/actions/caches?per_page=100>; rel=\"next\"",
        b"{\"actions_caches\":[{\"id\":12}]}",
      ),
      ("", b"{\"actions_caches\":[{\"id\":12},{\"id\":12}]}"),
    ] {
    let seen : Array[String] = []
    guard @github.Client::new(
        config=@github.ClientConfig::new(base_url="http://api.github.localhost"),
        transport=@github.Transport::new(send=request => {
          seen.push(request.verb())
          assert_eq(request.verb(), "GET")
          Ok(
            @github.RawResponse::new(
              status=200,
              body~,
              headers=if link.is_empty() { [] } else { [("Link", link)] },
            ),
          )
        }),
      )
      is Ok(client) else {
      fail("client")
    }
    guard @github_cli.parse(["cache", "delete", "--all"])
      is @github_cli.Business(options) else {
      fail("options")
    }
    guard @github_cli.RepositoryContext::parse("acme/widgets") is Ok(repository) else {
      fail("repo")
    }
    let result = @native.execute_github_business(
      options,
      client~,
      repository~,
      base_url="http://api.github.localhost",
    )
    assert_eq(result.exit_code(), 1)
    assert_eq(seen, ["GET"])
  }
}
