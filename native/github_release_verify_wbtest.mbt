///|
async test "release external proof retries transient failures with a fixed bound" {
  for recover in [false, true] {
    let mut calls = 0
    let response = release_bundle_fetch(
      "https://fixture.blob.core.windows.net/proof",
      _ => {
        calls += 1
        if calls == 1 {
          fail("connection reset")
        }
        @gh.RawHttpResponse::new(
          status=if recover && calls == 4 { 200 } else { 503 },
        )
      },
    )
    assert_eq(calls, 4)
    assert_eq(response.status(), if recover { 200 } else { 503 })
  }
  let mut calls = 0
  let response = release_bundle_fetch(
    "https://fixture.blob.core.windows.net/proof",
    _ => {
      calls += 1
      @gh.RawHttpResponse::new(status=404, body=b"not snappy")
    },
  )
  assert_eq(response.status(), 404)
  assert_eq(calls, 1)
}

///|
async test "release external proof cancellation does not trigger another fetch" {
  // Synchronize on entering backoff, rather than racing 25/200 ms timers under
  // the full suite's scheduler load. Exercise both retry paths.
  for transport_failure in [false, true] {
    let mut calls = 0
    let mut waiting = false
    let mut completed = false
    @async.with_task_group() <| group => {
      let task = group.spawn(() => {
        ignore(
          release_bundle_fetch(
            "https://fixture.blob.core.windows.net/proof",
            _ => {
              calls += 1
              if transport_failure {
                fail("synthetic transport failure")
              }
              @gh.RawHttpResponse::new(status=503)
            },
            wait=_ => {
              waiting = true
              @async.sleep(60000)
            },
          ),
        )
        completed = true
      })
      while !waiting {
        @async.pause()
      }
      task.cancel()
    }
    assert_false(completed)
    assert_eq(calls, 1)
  }
}

///|
fn snappy_literal_fixture(bytes : Bytes) -> Bytes {
  let output = @buffer.Buffer()
  let mut remaining = bytes.length()
  while remaining >= 128 {
    output.write_byte(((remaining & 127) | 128).to_byte())
    remaining = remaining >> 7
  }
  output.write_byte(remaining.to_byte())
  let length = bytes.length() - 1
  if length < 60 {
    output.write_byte((length << 2).to_byte())
  } else {
    output.write_byte(b'\xf4')
    output.write_byte((length & 255).to_byte())
    output.write_byte(((length >> 8) & 255).to_byte())
  }
  output.write_bytes(bytes)
  output.to_bytes()
}

///|
async test "Release command verifies externally compressed proof through the complete default TUF chain" {
  let directory = @fs.tmpdir(prefix="gh-release-default-trust-")
  defer @fs.rmdir(directory, recursive=true)
  let api_requests : Array[String] = []
  let public_requests : Array[String] = []
  let digest = "c5e17a62e06a1d201570249c61fae531e9244e1b"
  let bundle_url = "https://fixture.blob.core.windows.net/attestations/public-bundle"
  guard @github.Client::new(
      config=@github.ClientConfig::new(
        base_url="https://api.github.com",
        token="synthetic-api-only",
      ),
      transport=@github.Transport::new(send=request => {
        api_requests.push(request.path())
        assert_eq(request.verb(), "GET")
        let value : Json = match request.path() {
          "/repos/acme/widgets/git/ref/tags%2Fv6" =>
            { "object": { "sha": digest } }
          "/meta" => {}
          path if path ==
            "/repos/acme/widgets/attestations/sha1:" +
            digest +
            "?per_page=100&predicate_type=release" =>
            {
              "attestations": [
                { "initiator": "github", "bundle_url": bundle_url },
              ],
            }
          _ => fail("unexpected authenticated request")
        }
        Ok(
          @github.RawResponse::new(
            status=200,
            body=@utf8.encode(value.stringify()),
          ),
        )
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  guard @github_cli.parse(["release", "verify", "v6", "-R", "acme/widgets"])
    is @github_cli.Business(options) else {
    fail("options")
  }
  let result = execute_github_business(
    options,
    client~,
    base_url="https://api.github.com",
    cache_directory=directory,
    verification_time=1792540800L,
    public_fetch=url => {
      public_requests.push(url)
      if url == bundle_url {
        @gh.RawHttpResponse::new(
          status=200,
          body=snappy_literal_fixture(
            native_trust_fixture("github-release-bundle.json"),
          ),
        )
      } else {
        public_trust_fixture(url)
      }
    },
  )
  assert_eq(result.exit_code(), 0, msg=result.stderr())
  assert_true(result.stdout().contains("✓ Release v6 verified!"))
  assert_true(
    result
    .stdout()
    .contains(
      "artifact.zip\tsha256:e15b593c6ab8d7725a3cc82226ef816cac6bf9c70eed383bd459295cc65f5ec3",
    ),
  )
  assert_eq(api_requests.length(), 3)
  assert_eq(public_requests.length(), 12)
  assert_eq(public_requests[0], bundle_url)
  assert_true(@fs.exists(directory + "/github-release-trust/state.json"))
}
