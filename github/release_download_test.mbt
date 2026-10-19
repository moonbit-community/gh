///|
async fn release_download_fixture(
  responses : Array[Result[@github.RawResponse, @github.TransportError]],
  base_url~ : String = "https://api.github.com",
  path~ : String = "/repos/acme/widgets/releases/assets/77",
) -> (
  Result[@github.RawResponse, @github.GitHubError],
  Array[@github.Request],
  Array[String],
) {
  let seen : Array[@github.Request] = []
  let traces : Array[String] = []
  guard @github.Client::new(
      config=@github.ClientConfig::new(
        base_url~,
        token="fixture-download-token",
        trace_observer=record => traces.push(record.to_json_line()),
      ),
      transport=@github.Transport::new(send=request => {
        seen.push(request)
        match responses.get(seen.length() - 1) {
          Some(response) => response
          None => fail("unexpected release download request")
        }
      }),
    )
    is Ok(client) else {
    fail("fixture client setup failed")
  }
  (client.download_release_asset(path), seen, traces)
}

///|
fn release_download_has_header(
  request : @github.Request,
  name : String,
) -> Bool {
  request.headers().any(pair => pair.0.equal_ignore_ascii_case(name))
}

///|
async test "release download preserves binary body and authenticates only API request" {
  let (result, seen, _) = release_download_fixture([
    Ok(@github.RawResponse::new(status=200, body=[0, 255, 1, 128])),
  ])
  guard result is Ok(response) else { fail("direct download failed") }
  assert_eq(response.body(), [0, 255, 1, 128])
  assert_eq(seen.length(), 1)
  assert_eq(seen[0].verb(), "GET")
  assert_eq(seen[0].body(), None)
  assert_true(
    seen[0].headers().contains(("Accept", "application/octet-stream")),
  )
  assert_true(
    seen[0]
    .headers()
    .contains(("Authorization", "Bearer fixture-download-token")),
  )
  assert_true(release_download_has_header(seen[0], "X-GitHub-Api-Version"))
  let (invalid, invalid_seen, _) = release_download_fixture([], path="/user")
  assert_true(invalid is Err(@github.InvalidRequest(..)))
  assert_eq(invalid_seen.length(), 0)
}

///|
async test "release download preserves signed CDN URL and redacts credentials and traces" {
  let signed_url = "https://release-assets.githubusercontent.com/asset.bin?sig=signed%2Btoken%2Fvalue&sv=1&empty=&repeat=a&repeat=b"
  let (result, seen, traces) = release_download_fixture([
    Ok(@github.RawResponse::new(status=302, headers=[("Location", signed_url)])),
    Ok(@github.RawResponse::new(status=200, body=[255, 0, 13, 10])),
  ])
  guard result is Ok(response) else { fail("CDN download failed") }
  assert_eq(response.body(), [255, 0, 13, 10])
  assert_eq(seen.length(), 2)
  assert_eq(seen[1].url(), signed_url)
  assert_eq(seen[1].verb(), "GET")
  assert_eq(seen[1].body(), None)
  assert_false(release_download_has_header(seen[1], "authorization"))
  assert_false(release_download_has_header(seen[1], "x-github-api-version"))
  assert_true(release_download_has_header(seen[1], "user-agent"))
  assert_eq(traces.length(), 2)
  for trace in traces {
    assert_false(trace.contains("fixture-download-token"))
    assert_false(trace.contains("signed%2Btoken"))
    assert_false(trace.contains("sig="))
    assert_false(trace.contains("repeat="))
    assert_false(trace.contains("?"))
  }
}

///|
async test "release download relative same-origin redirect retains authentication" {
  let (result, seen, _) = release_download_fixture(
    [
      Ok(
        @github.RawResponse::new(status=307, headers=[
          ("location", "/download/77?download=1"),
        ]),
      ),
      Ok(@github.RawResponse::new(status=200, body=b"asset")),
    ],
    base_url="https://ghe.example/api/v3",
  )
  assert_true(result is Ok(_))
  assert_eq(seen.length(), 2)
  assert_eq(seen[1].url(), "https://ghe.example/download/77?download=1")
  assert_true(
    seen[1]
    .headers()
    .contains(("Authorization", "Bearer fixture-download-token")),
  )
  assert_true(release_download_has_header(seen[1], "X-GitHub-Api-Version"))
}

///|
async test "release download never restores API credentials after crossing to CDN" {
  let (result, seen, _) = release_download_fixture([
    Ok(
      @github.RawResponse::new(status=302, headers=[
        (
          "Location", "https://github-releases.githubusercontent.com/asset?sig=fixture",
        ),
      ]),
    ),
    Ok(
      @github.RawResponse::new(status=303, headers=[
        ("Location", "https://api.github.com/download/77"),
      ]),
    ),
    Ok(@github.RawResponse::new(status=200, body=b"asset")),
  ])
  assert_true(result is Ok(_))
  assert_eq(seen.length(), 3)
  assert_true(release_download_has_header(seen[0], "Authorization"))
  for index in 1..<3 {
    assert_eq(seen[index].verb(), "GET")
    assert_false(release_download_has_header(seen[index], "Authorization"))
    assert_false(
      release_download_has_header(seen[index], "X-GitHub-Api-Version"),
    )
  }
}

///|
async test "release download rejects unsafe or ambiguous redirects without following" {
  for
    headers in [
      [("Location", "https://evil.example/asset")],
      [("Location", "http://release-assets.githubusercontent.com/asset")],
      [("Location", "http://api.github.com/asset")],
      [
        (
          "Location", "https://release-assets.githubusercontent.com.evil.example/asset",
        ),
      ],
      [("Location", "//release-assets.githubusercontent.com/asset")],
      [
        ("Location", "https://release-assets.githubusercontent.com/asset"),
        ("location", "https://release-assets.githubusercontent.com/other"),
      ],
      [],
    ] {
    let (result, seen, _) = release_download_fixture([
      Ok(@github.RawResponse::new(status=302, headers~)),
    ])
    assert_true(result is Err(@github.InvalidRequest(..)))
    assert_eq(seen.length(), 1)
  }
  let (enterprise, enterprise_seen, _) = release_download_fixture(
    [
      Ok(
        @github.RawResponse::new(status=302, headers=[
          ("Location", "https://release-assets.githubusercontent.com/asset"),
        ]),
      ),
    ],
    base_url="https://ghe.example/api/v3",
  )
  assert_true(enterprise is Err(@github.InvalidRequest(..)))
  assert_eq(enterprise_seen.length(), 1)
}

///|
async test "release download bounds cycles and maximum redirects" {
  let (cycle, cycle_seen, _) = release_download_fixture([
    Ok(
      @github.RawResponse::new(status=302, headers=[
        ("Location", "/download/77"),
      ]),
    ),
    Ok(
      @github.RawResponse::new(status=302, headers=[
        ("Location", "/repos/acme/widgets/releases/assets/77"),
      ]),
    ),
  ])
  guard cycle is Err(@github.InvalidRequest(message~)) else {
    fail("cycle was accepted")
  }
  assert_true(message.contains("cycle"))
  assert_eq(cycle_seen.length(), 2)
  let redirects : Array[Result[@github.RawResponse, @github.TransportError]] = []
  for hop in 1..<=6 {
    redirects.push(
      Ok(
        @github.RawResponse::new(status=308, headers=[
          ("Location", "/download/" + hop.to_string()),
        ]),
      ),
    )
  }
  let (bounded, bounded_seen, _) = release_download_fixture(redirects)
  guard bounded is Err(@github.InvalidRequest(message~)) else {
    fail("unbounded redirects were accepted")
  }
  assert_true(message.contains("too many"))
  assert_eq(bounded_seen.length(), 6)
  redirects[5] = Ok(@github.RawResponse::new(status=200, body=b"asset"))
  let (five_hops, successful_seen, _) = release_download_fixture(redirects)
  assert_true(five_hops is Ok(_))
  assert_eq(successful_seen.length(), 6)
}

///|
async test "release download propagates HTTP transport and cancellation failures" {
  for redirect_first in [false, true] {
    for
      (failure, code) in [
        (
          Ok(@github.RawResponse::new(status=404, body=b"asset missing")),
          "http",
        ),
        (Err(@github.TransportError::Failed), "transport"),
        (Err(@github.TransportError::Cancelled), "cancelled"),
      ] {
      let responses = []
      if redirect_first {
        responses.push(
          Ok(
            @github.RawResponse::new(status=302, headers=[
              ("Location", "https://release-assets.githubusercontent.com/asset"),
            ]),
          ),
        )
      }
      responses.push(failure)
      let (result, seen, _) = release_download_fixture(responses)
      guard result is Err(error) else { fail("download failure was swallowed") }
      assert_eq(error.code(), code)
      if code == "http" {
        assert_eq(error.status(), Some(404))
        guard error.response() is Some(response) else {
          fail("HTTP response missing")
        }
        assert_eq(response.body(), b"asset missing")
      }
      assert_eq(seen.length(), if redirect_first { 2 } else { 1 })
    }
  }
}
