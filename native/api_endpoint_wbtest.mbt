///|
test "API URLs have a canonical credential scope and retain the query" {
  assert_true(
    api_absolute_endpoint("http://127.0.0.1:1234/a?q=1")
    is Ok(Some(("http://127.0.0.1:1234", "/a?q=1"))),
  )
  assert_true(
    api_absolute_endpoint("https://API.GITHUB.COM:443/user")
    is Ok(Some(("https://api.github.com", "/user"))),
  )
  assert_true(
    api_absolute_endpoint("https://api.github.com?q=1")
    is Ok(Some(("https://api.github.com", "/?q=1"))),
  )
  for
    url in [
      "https://user:secret@api.github.com/user", "http://github.com/user", "https://api.github.com/user#fragment",
      "https://api.github.com\\@other/user",
    ] {
    assert_true(api_absolute_endpoint(url) is Err(_))
  }
}

///|
test "API cache partitions include origin account and query fields" {
  let request = @github.Request::new(verb="GET", path="/same", query=[
    ("page", "1"),
  ])
  let page2 = @github.Request::new(verb="GET", path="/same", query=[
    ("page", "2"),
  ])
  let first = api_cache_key(request, "https://api.github.com\naccount-a")
  assert_true(
    first != api_cache_key(request, "https://other.example\naccount-a"),
  )
  assert_true(
    first != api_cache_key(request, "https://api.github.com\naccount-b"),
  )
  assert_true(
    first != api_cache_key(page2, "https://api.github.com\naccount-a"),
  )
}
