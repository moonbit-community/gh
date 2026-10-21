///|
async test "streamed release shares redirect policy and removes credentials permanently" {
  let seen : Array[@github.Request] = []
  let traces : Array[String] = []
  let transport = @github.Transport::new(
    send=_ => fail("streamed release used buffered transport"),
    receive=(request, sink) => {
      seen.push(request)
      let head = match seen.length() {
        1 =>
          @gh.RawResponseHead::new(status=302, headers=[
            (
              "Location", "https://release-assets.githubusercontent.com/asset?sig=private-signature",
            ),
          ])
        2 =>
          @gh.RawResponseHead::new(status=307, headers=[
            ("Location", "https://api.github.com/download/asset"),
          ])
        _ => @gh.RawResponseHead::new(status=200)
      }
      if !sink.headers(head) {
        return Ok(
          @gh.RawDownloadResult::new(head~, bytes_received=0L, complete=false),
        )
      }
      sink.chunk(b"\x00\xff")
      sink.chunk(b"\x01\x80")
      Ok(@gh.RawDownloadResult::new(head~, bytes_received=4L, complete=true))
    },
  )
  guard @github.Client::new(
      config=@github.ClientConfig::new(
        base_url="https://api.github.com",
        token="stream-fixture-token",
      ),
      transport~,
      trace_observer=record => traces.push(record.to_json_line()),
    )
    is Ok(client) else {
    fail("invalid fixture client")
  }
  let chunks : Array[Bytes] = []
  let mut headers = 0
  let result = client.download_release_asset_into(
    "/repos/acme/widgets/releases/assets/7",
    @gh.RawResponseSink::new(
      headers=head => {
        headers += 1
        assert_eq(head.status(), 200)
        true
      },
      chunk=bytes => chunks.push(bytes),
    ),
  )
  guard result is Ok(result) else { fail("streamed release failed") }
  assert_true(result.complete())
  assert_eq(result.bytes_received(), 4L)
  assert_eq(chunks, [b"\x00\xff", b"\x01\x80"])
  assert_eq(headers, 1)
  assert_eq(seen.length(), 3)
  assert_true(seen[0].headers().any(pair => pair.0 == "Authorization"))
  for request in seen[1:] {
    assert_false(
      request
      .headers()
      .any(pair => {
        pair.0.equal_ignore_ascii_case("authorization") ||
        pair.0.equal_ignore_ascii_case("x-github-api-version")
      }),
    )
  }
  assert_eq(traces.length(), 3)
  for trace in traces {
    assert_false(trace.contains("stream-fixture-token"))
    assert_false(trace.contains("private-signature"))
    assert_false(trace.contains("sig="))
  }
}

///|
async test "streamed release rejects foreign redirects without opening another connection" {
  let mut calls = 0
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.com"),
      transport=@github.Transport::new(
        send=_ => fail("unexpected buffered request"),
        receive=(_, sink) => {
          calls += 1
          let head = @gh.RawResponseHead::new(status=302, headers=[
            ("Location", "https://evil.example/asset"),
          ])
          assert_false(sink.headers(head))
          Ok(
            @gh.RawDownloadResult::new(head~, bytes_received=0L, complete=false),
          )
        },
      ),
    )
    is Ok(client) else {
    fail("invalid fixture client")
  }
  let result = client.download_release_asset_into(
    "/repos/acme/widgets/releases/assets/7",
    @gh.RawResponseSink::new(headers=_ => fail("redirect exposed as asset"), chunk=_ => {
      fail("unexpected bytes")
    }),
  )
  assert_true(result is Err(@github.InvalidRequest(..)))
  assert_eq(calls, 1)
}

///|
async test "Actions streams signed storage redirects without credentials" {
  let seen : Array[@github.Request] = []
  guard @github.Client::new(
      config=@github.ClientConfig::new(
        base_url="https://api.github.com",
        token="fixture-token",
      ),
      transport=@github.Transport::new(send=_ => fail("buffered"), receive=(
        request,
        sink,
      ) => {
        seen.push(request)
        let head = if seen.length() == 1 {
          @gh.RawResponseHead::new(status=302, headers=[
            (
              "Location", "https://productionresultssa1.blob.core.windows.net/artifact?sig=secret",
            ),
          ])
        } else {
          @gh.RawResponseHead::new(status=200)
        }
        let accepted = sink.headers(head)
        if accepted {
          sink.chunk(b"zip")
        }
        Ok(
          @gh.RawDownloadResult::new(
            head~,
            bytes_received=if accepted { 3L } else { 0L },
            complete=accepted,
          ),
        )
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  let output : Array[Bytes] = []
  assert_true(
    client.download_actions_archive_into(
      "/repos/me/test/actions/artifacts/3/zip",
      @gh.RawResponseSink::new(headers=_ => true, chunk=chunk => {
        output.push(chunk)
      }),
    )
    is Ok(_),
  )
  assert_eq(output, [b"zip"])
  assert_eq(seen.length(), 2)
  assert_true(seen[0].headers().any(pair => pair.0 == "Authorization"))
  assert_false(seen[1].headers().any(pair => pair.0 == "Authorization"))
  for
    origin in [
      "https://blob.core.windows.net", "https://evil.blob.core.windows.net.evil.com",
      "https://user@storage.blob.core.windows.net", "http://storage.blob.core.windows.net",
      "https://storage.blob.core.windows.net:444", "https://storage.blob.core.windows.net/path",
    ] {
    assert_false(@github.actions_download_origin(origin))
  }
}

///|
async test "source archive rewrites only first Codeload legacy path and strips credentials" {
  let requests : Array[@github.Request] = []
  guard @github.Client::new(
      config=@github.ClientConfig::new(
        base_url="https://api.github.com",
        token="archive-fixture-token",
      ),
      transport=@github.Transport::new(send=_ => fail("buffered"), receive=(
        request,
        sink,
      ) => {
        requests.push(request)
        let head = if requests.length() == 1 {
          @gh.RawResponseHead::new(status=302, headers=[
            (
              "Location", "https://codeload.github.com/acme/widgets/legacy.zip/refs/tags/v1",
            ),
          ])
        } else {
          @gh.RawResponseHead::new(status=200)
        }
        let accepted = sink.headers(head)
        if accepted {
          sink.chunk(b"source")
        }
        Ok(
          @gh.RawDownloadResult::new(
            head~,
            bytes_received=if accepted { 6L } else { 0L },
            complete=accepted,
          ),
        )
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  assert_true(
    client.download_release_archive_into(
      "/repos/acme/widgets/zipball/v1",
      @gh.RawResponseSink::new(headers=_ => true, chunk=_ => ()),
    )
    is Ok(_),
  )
  assert_eq(requests.length(), 2)
  assert_eq(
    requests[1].url(),
    "https://codeload.github.com/acme/widgets/zip/refs/tags/v1",
  )
  assert_true(
    requests[0]
    .headers()
    .contains(("Accept", "application/octet-stream, application/json")),
  )
  assert_false(
    requests[1]
    .headers()
    .any(pair => pair.0.equal_ignore_ascii_case("Authorization")),
  )
  assert_true(
    client.download_release_archive_into(
      "/repos/acme/widgets/issues/1",
      @gh.RawResponseSink::new(headers=_ => true, chunk=_ => ()),
    )
    is Err(@github.InvalidRequest(..)),
  )
  assert_eq(requests.length(), 2)
}
