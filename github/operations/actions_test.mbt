///|
async test "artifact listing follows exact collection links and retains API order" {
  let seen : Array[String] = []
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.com"),
      transport=@github.Transport::new(send=request => {
        seen.push(request.path())
        let number = seen.length()
        let body : Json = {
          "artifacts": [
            {
              "id": number,
              "name": "same-name",
              "expired": number == 2,
              "archive_download_url": "https://api.github.com/repos/me/test/actions/artifacts/\{number}/zip",
            },
          ],
        }
        Ok(
          @github.RawResponse::new(
            status=200,
            body=@utf8.encode(body.stringify()),
            headers=if number == 1 {
              [("Link", "<?page=2&per_page=100>; rel=\"next\"")]
            } else {
              []
            },
          ),
        )
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  guard @operations.list_artifacts(client, "me/test", run_id="123")
    is Ok(values) else {
    fail("listing")
  }
  assert_eq(values.map(value => value.id()), ["1", "2"])
  assert_eq(values.map(value => value.expired()), [false, true])
  assert_eq(seen, [
    "/repos/me/test/actions/runs/123/artifacts?per_page=100", "/repos/me/test/actions/runs/123/artifacts?page=2&per_page=100",
  ])
}

///|
async test "artifact listing refuses cross origin pagination and mismatched download URLs" {
  for mismatch in [false, true] {
    let mut calls = 0
    guard @github.Client::new(
        config=@github.ClientConfig::new(base_url="https://api.github.com"),
        transport=@github.Transport::new(send=_ => {
          calls += 1
          Ok(
            @github.RawResponse::new(
              status=200,
              body=if mismatch {
                b"{\"artifacts\":[{\"id\":1,\"name\":\"a\",\"expired\":false,\"archive_download_url\":\"https://evil.example/zip\"}]}"
              } else {
                b"{\"artifacts\":[]}"
              },
              headers=[("Link", "<https://evil.example/next>; rel=\"next\"")],
            ),
          )
        }),
      )
      is Ok(client) else {
      fail("client")
    }
    assert_true(
      @operations.list_artifacts(client, "me/test") is Err(@github.Decode(..)),
    )
    assert_eq(calls, 1)
  }
}
