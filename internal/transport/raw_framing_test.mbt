///|
async fn with_raw_wire(
  wire : Bytes,
  run : async (@gh.RawTransport) -> Unit,
  keep_open~ : Bool = false,
  max_response_bytes~ : Int32 = 16,
) -> Unit {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      ignore(@io.Reader::read_until(conn, "\r\n\r\n"))
      @io.Writer::write(conn, wire)
      if keep_open {
        @async.sleep(5000)
      }
    }
    run(
      @transport.native_raw_transport(
        base_url="http://127.0.0.1:\{server.addr.port()}",
        timeout_ms=1000,
        max_response_bytes~,
      ),
    )
  }
}

///|
async test "raw framing preserves repeated headers cookies and opaque body" {
  with_raw_wire(
    b"HTTP/1.1 200 OK\r\nX-Repeat: first\r\nX-Repeat: second\r\nSet-Cookie: a=one\r\nSet-Cookie: b=two\r\nContent-Type: application/octet-stream\r\nContent-Length: 4\r\n\r\n\x00\xff\x01\xfe",
  ) <| transport => {
    let response = transport.send(@gh.RawRequest::new(verb="GET", path="/raw"))
    assert_eq(response.body(), b"\x00\xff\x01\xfe")
    assert_eq(response.reason_phrase(), Some("OK"))
    assert_eq(response.headers().filter(pair => pair.0 == "x-repeat"), [
      ("x-repeat", "first"),
      ("x-repeat", "second"),
    ])
    assert_eq(
      response.headers().filter(pair => pair.0 == "set-cookie").length(),
      2,
    )
  }
}

///|
async test "raw framing HEAD 204 and 304 end without body or EOF" {
  for
    (verb, wire, status) in [
      ("HEAD", b"HTTP/1.1 200 OK\r\nContent-Length: 123456\r\n\r\n", 200),
      ("GET", b"HTTP/1.1 204 No Content\r\n\r\n", 204),
      (
        "GET", b"HTTP/1.1 304 Not Modified\r\nContent-Length: 123456\r\n\r\n", 304,
      ),
    ] {
    with_raw_wire(wire, keep_open=true) <| transport => {
      let response = transport.send(@gh.RawRequest::new(verb~, path="/empty"))
      assert_eq(response.status(), status)
      assert_eq(response.body(), b"")
    }
  }
}

///|
async test "raw framing accepts bounded informational responses and chunked bytes" {
  with_raw_wire(
    b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\nHTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n\x00\xff\r\n2\r\n\x01\xfe\r\n0\r\nX-Trailer: ignored\r\n\r\n",
  ) <| transport => {
    let response = transport.send(
      @gh.RawRequest::new(verb="GET", path="/chunks"),
    )
    assert_eq(response.status(), 200)
    assert_eq(response.body(), b"\x00\xff\x01\xfe")
    assert_eq(response.header("link"), None)
    assert_eq(response.header("x-trailer"), None)
  }
}

///|
async test "raw transport sends extension methods and repeated request fields" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      let request = @io.Reader::read_until(conn, "\r\n\r\n").unwrap()
      assert_true(
        request.has_prefix("PROPFIND /opaque%2Fname?x=%FF HTTP/1.1\r\n"),
      )
      assert_true(request.contains("x-repeat: first\r\nx-repeat: second\r\n"))
      @io.Writer::write(conn, b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
    }
    let transport = @transport.native_raw_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
    )
    let response = transport.send(
      @gh.RawRequest::new(verb="PROPFIND", path="/opaque%2Fname?x=%FF", headers=[
        ("X-Repeat", "first"),
        ("x-repeat", "second"),
      ]),
    )
    assert_eq(response.status(), 200)
  }
}

///|
async test "raw transport unknown stream length uses chunk framing" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      let head = @io.Reader::read_until(conn, "\r\n\r\n").unwrap()
      assert_true(head.to_lower().contains("transfer-encoding: chunked"))
      assert_false(head.contains("content-length:"))
      let body = @io.Reader::read_exactly(conn, 19)
      assert_eq(body, b"2\r\n\x00\xff\r\n2\r\n\x01\xfe\r\n0\r\n\r\n")
      @io.Writer::write(
        conn, b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n",
      )
    }
    let mut count = 0
    let stream = @gh.RawBodyStream::new(next=() => {
      count += 1
      match count {
        1 => Some(b"\x00\xff")
        2 => Some(b"\x01\xfe")
        _ => None
      }
    })
    let transport = @transport.native_raw_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
    )
    assert_eq(
      transport
      .send(@gh.RawRequest::from_stream(verb="POST", path="/stream", stream~))
      .status(),
      201,
    )
  }
}

///|
async test "raw transport propagates caller cancellation and request deadline" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    let mut request_seen = false
    group.spawn_bg(no_wait=true) <| () => {
      for _ in 0..<2 {
        let (conn, _) = server.accept()
        defer conn.close()
        ignore(@io.Reader::read_until(conn, "\r\n\r\n"))
        request_seen = true
        ignore(@io.Reader::read_some(conn))
      }
    }
    let origin = "http://127.0.0.1:\{server.addr.port()}"
    let transport = @transport.native_raw_transport(
      base_url=origin,
      timeout_ms=1000,
    )
    let task = group.spawn(() => {
      transport.send(@gh.RawRequest::new(verb="GET", path="/cancel"))
    })
    while !request_seen {
      @async.pause()
    }
    task.cancel()
    let cancelled = try {
      ignore(task.wait())
      false
    } catch {
      @async.WaitedTaskAlreadyCancelled => true
      _ => false
    }
    assert_true(cancelled)
    let transport = @transport.native_raw_transport(
      base_url=origin,
      timeout_ms=50,
    )
    let timed_out = try {
      ignore(transport.send(@gh.RawRequest::new(verb="GET", path="/timeout")))
      false
    } catch {
      @async.TimeoutError => true
      _ => false
    }
    assert_true(timed_out)
  }
}
