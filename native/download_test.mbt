///|
async test "download atomically publishes binary and refuses an existing target" {
  let directory = @fs.tmpdir(prefix="gh-download-file-")
  defer @fs.rmdir(directory, recursive=true)
  let target = directory + "/asset.bin"
  let transport = @gh.RawTransport::new(origin="https://example.test", send=_ => {
    @gh.RawHttpResponse::new(status=200, body=b"\x00\xff\x01")
  })
  let request = @gh.RawRequest::new(verb="GET", path="/asset")
  let result = @native.download_to_file(transport, request, target)
  assert_true(result.complete())
  assert_eq(@fs.read_file(target).binary(), b"\x00\xff\x01")
  let rejected = try {
    ignore(@native.download_to_file(transport, request, target))
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  assert_eq(@fs.readdir(directory), ["asset.bin"])
}

///|
async test "failed download and HTTP rejection preserve prior file and clean temporary data" {
  let directory = @fs.tmpdir(prefix="gh-download-file-")
  defer @fs.rmdir(directory, recursive=true)
  let target = directory + "/asset.bin"
  @fs.write_file(target, b"original")
  let request = @gh.RawRequest::new(verb="GET", path="/asset")
  for fail_stream in [false, true] {
    let transport = @gh.RawTransport::new(
      origin="https://example.test",
      send=_ => fail("stream callback expected"),
      receive=(_, sink) => {
        let head = @gh.RawResponseHead::new(
          status=if fail_stream { 200 } else { 404 },
        )
        if sink.headers(head) {
          sink.chunk(b"incomplete")
          fail("connection ended early")
        }
        @gh.RawDownloadResult::new(head~, bytes_received=0L, complete=false)
      },
    )
    let failed = try {
      let result = @native.download_to_file(
        transport,
        request,
        target,
        replace=true,
      )
      assert_eq(result.head().status(), 404)
      false
    } catch {
      _ => true
    }
    assert_eq(failed, fail_stream)
    assert_eq(@fs.read_file(target).binary(), b"original")
    assert_eq(@fs.readdir(directory), ["asset.bin"])
  }
}

///|
async test "cancelled download cleans partial file without replacing existing data" {
  let directory = @fs.tmpdir(prefix="gh-download-cancel-")
  defer @fs.rmdir(directory, recursive=true)
  let target = directory + "/asset.bin"
  @fs.write_file(target, b"original")
  let transport = @gh.RawTransport::new(
    origin="https://example.test",
    send=_ => fail("stream callback expected"),
    receive=(_, sink) => {
      ignore(sink.headers(@gh.RawResponseHead::new(status=200)))
      sink.chunk(b"partial")
      @async.sleep(10000)
      fail("download should have been cancelled")
    },
  )
  let cancelled = try {
    @async.with_timeout(100, () => {
      ignore(
        @native.download_to_file(
          transport,
          @gh.RawRequest::new(verb="GET", path="/asset"),
          target,
          replace=true,
        ),
      )
    })
    false
  } catch {
    _ => true
  }
  assert_true(cancelled)
  assert_eq(@fs.read_file(target).binary(), b"original")
  assert_eq(@fs.readdir(directory), ["asset.bin"])
}
