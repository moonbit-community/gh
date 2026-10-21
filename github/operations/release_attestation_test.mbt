///|
async test "release proof list and trust domain recover from server errors only" {
  let calls : Map[String, Int32] = Map([])
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.com"),
      transport=@github.Transport::new(send=request => {
        let path = request.path()
        let count = calls.get(path).unwrap_or(0) + 1
        calls[path] = count
        Ok(
          @github.RawResponse::new(
            status=if count == 1 { 503 } else { 200 },
            body=if path == "/meta" {
              b"{\"domains\":{\"artifact_attestations\":{\"trust_domain\":\"dotcom\"}}}"
            } else {
              b"{\"attestations\":[{\"initiator\":\"github\",\"bundle\":{}}]}"
            },
          ),
        )
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  guard @operations.list_release_attestations(
      client, "acme/widgets", "sha1:abcdef",
    )
    is Ok(values) else {
    fail("list did not retry")
  }
  assert_eq(values.length(), 1)
  assert_true(@operations.release_trust_domain(client) is Ok("dotcom"))
  assert_true(calls.values().all(value => value == 2))
}

///|
async test "release proof listing does not retry permission failures or malformed JSON" {
  for status in [403, 429, 200] {
    let mut calls = 0
    guard @github.Client::new(
        config=@github.ClientConfig::new(base_url="https://api.github.com"),
        transport=@github.Transport::new(send=_ => {
          calls += 1
          Ok(@github.RawResponse::new(status~, body=b"invalid"))
        }),
      )
      is Ok(client) else {
      fail("client")
    }
    assert_true(
      @operations.list_release_attestations(
        client, "acme/widgets", "sha1:abcdef",
      )
      is Err(_),
    )
    assert_eq(calls, 1)
  }
}
