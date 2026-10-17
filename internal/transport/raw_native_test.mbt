///|
async test "raw transport preserves binary body with HEAD and OPTIONS" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      for expected in [@http.Head, @http.Options] {
        let (conn, _) = server.accept()
        defer conn.close()
        let request = conn.read_request()
        assert_eq(request.meth, expected)
        assert_eq(request.path, "/opaque")
        conn.send_response(200, "OK", extra_headers={
          "X-Repeat": "one",
          "X-Repeat-2": "two",
        })
        if expected is @http.Head {
          conn.end_response()
        } else {
          conn..write(b"\x00\xff\x01\x00").end_response()
        }
      }
    }
    let transport = @transport.native_raw_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
    )
    for verb in ["HEAD", "OPTIONS"] {
      let response = transport.send(@gh.RawRequest::new(verb~, path="/opaque"))
      assert_eq(response.status(), 200)
      assert_eq(
        response.body(),
        if verb == "HEAD" {
          b""
        } else {
          b"\x00\xff\x01\x00"
        },
      )
      assert_eq(response.header("x-repeat"), Some("one"))
      assert_true(response.headers().length() >= 2)
    }
  }
}

///|
async test "raw transport sends byte and streaming request bodies" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      for expected in [b"\x00\xffA", @utf8.encode("streamed")] {
        let (conn, _) = server.accept()
        defer conn.close()
        let request = conn.read_request()
        assert_eq(request.meth, @http.Post)
        assert_eq(conn.read_all().binary(), expected)
        conn.send_response(201, "Created")
        conn..write(b"\x01\x02\x03").end_response()
      }
    }
    let transport = @transport.native_raw_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
    )
    let direct = transport.send(
      @gh.RawRequest::new(verb="POST", path="/upload", body=[0, 255, b'A']),
    )
    assert_eq(direct.status(), 201)
    assert_eq(direct.body(), [1, 2, 3])
    let chunks : Array[Bytes] = [@utf8.encode("str"), @utf8.encode("eamed")]
    let mut index = 0
    let stream = @gh.RawBodyStream::new(
      next=() => {
        if index >= chunks.length() {
          None
        } else {
          let chunk = chunks[index]
          index += 1
          Some(chunk)
        }
      },
      length=8,
    )
    let streamed = transport.send(
      @gh.RawRequest::from_stream(verb="POST", path="/upload", stream~),
    )
    assert_eq(streamed.status(), 201)
    assert_eq(streamed.body(), [1, 2, 3])
  }
}

///|
async test "raw transport returns redirects and does not retry" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  let mut calls = 0
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      calls += 1
      ignore(conn.read_request())
      conn.send_response(302, "Found", extra_headers={
        "Location": "http://127.0.0.1:1/private",
      })
      conn..write(b"\x09\x08").end_response()
    }
    let transport = @transport.native_raw_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
    )
    let response = transport.send(
      @gh.RawRequest::new(verb="GET", path="/redirect"),
    )
    assert_eq(response.status(), 302)
    assert_eq(response.body(), [9, 8])
    assert_eq(response.header("location"), Some("http://127.0.0.1:1/private"))
    assert_eq(calls, 1)
  }
}

///|
async test "raw response cap rejects oversized bytes" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      ignore(conn.read_request())
      conn.send_response(200, "OK")
      conn..write(b"\x01\x02\x03\x04").end_response()
    }
    let transport = @transport.native_raw_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
      max_response_bytes=3,
    )
    let rejected = try {
      ignore(transport.send(@gh.RawRequest::new(verb="GET", path="/too-large")))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
test "raw transport rejects invalid origin before I/O" {
  for
    base_url in [
      "http://example.invalid", "https://user:secret@example.invalid",
    ] {
    let rejected = try {
      ignore(@transport.native_raw_transport(base_url~))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
async test "raw transport streams files and pipe readers without text conversion" {
  let directory = @fs.tmpdir(prefix="gh-raw-body-")
  defer @fs.rmdir(directory, recursive=true)
  let path = directory + "/body.bin"
  let bytes = b"\x00\xff\xfe\x01"
  @fs.write_file(path, bytes)
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  let (reader, writer) = @io.pipe()
  defer reader.close()
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer writer.close()
      writer.write(bytes)
    }
    group.spawn_bg() <| () => {
      for _ in 0..<2 {
        let (conn, _) = server.accept()
        defer conn.close()
        ignore(conn.read_request())
        assert_eq(conn.read_all().binary(), bytes)
        conn.send_response(204, "No Content")
        conn.end_response()
      }
    }
    let transport = @transport.native_raw_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
    )
    for
      stream in [
        @transport.raw_body_from_reader(file, length=4),
        @transport.raw_body_from_reader(reader),
      ] {
      let response = transport.send(
        @gh.RawRequest::from_stream(verb="POST", path="/binary", stream~),
      )
      assert_eq(response.status(), 204)
      assert_eq(response.body(), b"")
    }
  }
}

///|
async test "raw transport rejects streaming length mismatch and empty chunks" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      for _ in 0..<3 {
        let (conn, _) = server.accept()
        defer conn.close()
        ignore(conn.read_all())
      }
    }
    let transport = @transport.native_raw_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
      timeout_ms=1000,
    )
    for (chunk, length) in [(b"abc", 2), (b"a", 2), (b"", 0)] {
      let mut sent = false
      let stream = @gh.RawBodyStream::new(length~, next=() => {
        if sent {
          None
        } else {
          sent = true
          Some(chunk)
        }
      })
      let rejected = try {
        ignore(
          transport.send(
            @gh.RawRequest::from_stream(verb="PUT", path="/stream", stream~),
          ),
        )
        false
      } catch {
        @async.TimeoutError => false
        _ => true
      }
      assert_true(rejected)
    }
  }
}
