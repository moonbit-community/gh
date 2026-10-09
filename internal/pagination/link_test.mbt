///|
test "next links resolve to the same canonical resource and query" {
  for
    target in [
      "https://MOONHUB.EXAMPLE:443/api/v1/repos/alice/demo/issues?page=2&per_page=30",
      "/api/v1/repos/alice/demo/issues?per_page=30&page=2", "?page=2&per_page=30",
      "issues?page=2&per_page=30",
    ] {
    match
      @pagination.next_path(
        "<\{target}>; rel=next",
        origin="https://moonhub.example",
        current_path="/repos/alice/demo/issues?page=1&per_page=30",
      ) {
      Ok(next) =>
        assert_eq(next, Some("/repos/alice/demo/issues?page=2&per_page=30"))
      Err(_) => fail("valid same-resource next link rejected")
    }
  }
  match
    @pagination.next_path(
      "</custom/repos?page=4&per_page=10>; rel=next",
      origin="https://moonhub.example",
      current_path="/repos?page=3&per_page=10",
      api_prefix="/custom",
    ) {
    Ok(next) => assert_eq(next, Some("/repos?page=4&per_page=10"))
    Err(_) => fail("custom prefix rejected")
  }
}

///|
test "link parsing respects commas and quoted values" {
  let link =
    #|<https://elsewhere.example/a,b>; rel="prev"; title="old, \"quoted\" page", <?page=2&per_page=30>; title="next, page"; REL="alternate NEXT"
  match
    @pagination.next_path(
      link,
      origin="https://moonhub.example",
      current_path="/repos?page=1&per_page=30",
    ) {
    Ok(next) => assert_eq(next, Some("/repos?page=2&per_page=30"))
    Err(_) => fail("quoted list parsing failed")
  }
  for link in ["", " \t ", "<https://elsewhere.example/a,b>; rel=prev"] {
    assert_true(
      @pagination.next_path(
        link,
        origin="https://moonhub.example",
        current_path="/repos?page=1&per_page=30",
      )
      is Ok(None),
    )
  }
}

///|
test "next links cannot change origin path or API prefix" {
  for
    target in [
      "https://evil.example/api/v1/repos?page=2&per_page=30", "https://moonhub.example.evil/api/v1/repos?page=2&per_page=30",
      "https://user@moonhub.example/api/v1/repos?page=2&per_page=30", "http://moonhub.example/api/v1/repos?page=2&per_page=30",
      "https://moonhub.example:444/api/v1/repos?page=2&per_page=30", "//evil.example/api/v1/repos?page=2&per_page=30",
      "/api/v2/repos?page=2&per_page=30", "/api/v10/repos?page=2&per_page=30", "/api/v1/user?page=2&per_page=30",
      "/api/v1/repos/../user?page=2&per_page=30", "/api/v1/%72epos?page=2&per_page=30",
      "/api/v1/repos?page=2&per_page=30#fragment", "/api/v1/repos%2F..%2Fuser?page=2&per_page=30",
      "/api/v1/repos\\user?page=2&per_page=30",
    ] {
    assert_true(
      @pagination.next_path(
        "<\{target}>; rel=next",
        origin="https://moonhub.example",
        current_path="/repos?page=1&per_page=30",
      )
      is Err(@gh.Decode(..)),
    )
  }
}

///|
test "pagination must advance exactly one page with unchanged page size" {
  for
    query in [
      "page=1&per_page=30", "page=3&per_page=30", "page=2&per_page=31", "page=2",
      "page=2&per_page=30&token=secret", "page=2&per_page=30&filter=open", "page=2&per_page=30&page=2",
      "page=2&per_page=30&per_page=30", "page=02&per_page=30", "page=%32&per_page=30",
      "page=2&per_page=030", "page=0&per_page=30", "page=-2&per_page=30", "page=1000001&per_page=30",
      "page=9999999999999999&per_page=30", "page=2&per_page=0", "page=2&per_page=101",
      "page=2&per_page=30&",
    ] {
    assert_true(
      @pagination.next_path(
        "<?\{query}>; rel=next",
        origin="https://moonhub.example",
        current_path="/repos?page=1&per_page=30",
      )
      is Err(@gh.Decode(..)),
    )
  }
}

///|
test "ambiguous malformed and anchored Link headers fail closed" {
  for
    link in [
      "<?page=2&per_page=30>; rel=next, <?page=2&per_page=30>; rel=next", "<?page=2&per_page=30>; rel=next; rel=prev",
      "<?page=2&per_page=30>; rel=next; anchor=other", "<?page=2&per_page=30>; rel",
      "<?page=2&per_page=30>; rel=", "<?page=2&per_page=30>; rel=\"next", "<?page=2&per_page=30>; rel=next,",
      "<?page=2&per_page=30>; rel=next garbage", "<?page=2&per_page=30; rel=next",
      "?page=2&per_page=30; rel=next", "<?page=2&per_page=30>; rel=next\r\nX-Secret: sensitive",
      "<?page=2&per_page=30>; title=\"中文\"; rel=next",
    ] {
    assert_true(
      @pagination.next_path(
        link,
        origin="https://moonhub.example",
        current_path="/repos?page=1&per_page=30",
      )
      is Err(@gh.Decode(..)),
    )
  }
}

///|
test "Link size is bounded and invalid values never appear in errors" {
  let oversized = StringBuilder()
  for _ in 0..<65537 {
    oversized.write_char(' ')
  }
  for
    link in [
      oversized.to_string(),
      "<https://secret.invalid/api/v1/repos?page=2&per_page=30>; rel=next",
    ] {
    match
      @pagination.next_path(
        link,
        origin="https://moonhub.example",
        current_path="/repos?page=1&per_page=30",
      ) {
      Err(@gh.Decode(message~)) => assert_eq(message, "invalid pagination link")
      _ => fail("expected bounded safe decode error")
    }
  }
}
