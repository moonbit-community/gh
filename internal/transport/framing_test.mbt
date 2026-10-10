///|
async fn with_wire_response(
  wire : String,
  run : async (@gh.Transport) -> Unit,
  keep_open? : Bool = false,
  max_response_bytes? : Int = 8,
  fragments? : Array[String] = [],
) -> Unit {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      let request = @http.ServerConnection::new(conn)
      ignore(request.read_request())
      @io.Writer::write(conn, wire)
      for fragment in fragments {
        @async.sleep(10)
        @io.Writer::write(conn, fragment)
      }
      if keep_open {
        @async.sleep(5000)
      }
    }
    run(
      @transport.native_transport(
        base_url="http://127.0.0.1:\{server.addr.port()}",
        timeout_ms=2000,
        max_response_bytes~,
      ),
    )
  }
}

///|
async test "oversized response framing is rejected before EOF or timeout" {
  let head = "HTTP/1.1 200 OK\r\n"
  let chunked = head + "Transfer-Encoding: chunked\r\n\r\n"
  for
    wire in [
      "HTTP/1.1 200 " + "x".repeat(8193),
      head + "X-Large: " + "x".repeat(8193),
      head + "X-Repeated: x\r\n".repeat(101),
      head + "Set-Cookie: x=y\r\n".repeat(101),
      head + ("X-Large: " + "x".repeat(8000) + "\r\n").repeat(9),
      chunked + "1;" + "x".repeat(8193),
      chunked + "0\r\nX-Large: " + "x".repeat(8193),
      chunked + "0\r\n" + "X-Repeated: x\r\n".repeat(101),
      chunked + "0\r\n" + ("X-Large: " + "x".repeat(8000) + "\r\n").repeat(9),
    ] {
    with_wire_response(wire, keep_open=true) <| transport => {
      let rejected = try {
        ignore(transport.send(@gh.Request::new(verb=Get, path="/api/v1/user")))
        false
      } catch {
        @http1.Http1Error::LimitExceeded(_) => true
        _ => false
      }
      assert_true(rejected)
    }
  }
}

///|
async test "framing limits accept exact line count and byte boundaries" {
  let head = "HTTP/1.1 200 OK\r\n"
  for
    wire in [
      "HTTP/1.1 200 " + "x".repeat(8179) + "\r\nContent-Length: 0\r\n\r\n",
      head + "X: x\r\n".repeat(99) + "Content-Length: 0\r\n\r\n",
      head + ("X: " + "x".repeat(8187) + "\r\n").repeat(8) + "\r\n",
      head + "Transfer-Encoding: chunked\r\n\r\n0\r\n" + "X: x\r\n".repeat(100) + "\r\n",
    ] {
    with_wire_response(wire) <| transport => {
      assert_eq(
        transport.send(@gh.Request::new(verb=Get, path="/api/v1/user")).body,
        "",
      )
    }
  }
  for
    (start, rest) in [
      ("HTTP/1.1 200 " + "x".repeat(8178), "\nContent-Length: 0\r\n\r\n"),
      (head + "X: " + "x".repeat(8188), "\nContent-Length: 0\r\n\r\n"),
      (head + "Transfer-Encoding: chunked\r\n\r\n1;" + "x".repeat(8189), "\na\r\n0\r\n\r\n"),
    ] {
    with_wire_response(start, fragments=["\r", rest]) <| transport => {
      assert_eq(
        transport.send(@gh.Request::new(verb=Get, path="/api/v1/user")).status,
        200,
      )
    }
  }
}

///|
async test "framing rejects truncated ambiguous and oversized bodies" {
  let head = "HTTP/1.1 200 OK\r\n"
  for
    wire in [
      "",
      "HTTP/1.1 200",
      head + "X: incomplete",
      head + "Content-Length: 4\r\n\r\nabc",
      head + "Transfer-Encoding: chunked\r\n\r\n4\r\nabc",
      head + "Content-Length: 9\r\n\r\n123456789",
      head + "\r\n123456789",
      head + "Transfer-Encoding: chunked\r\n\r\n9\r\n123456789\r\n0\r\n\r\n",
      head + "Transfer-Encoding: chunked\r\n\r\n1\r\na\r\n7fffffff\r\n12345678",
      head + "Content-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
      head + "Content-Length: 1\r\nContent-Length: 2\r\n\r\na",
      head + "Content-Encoding: identity\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n",
      head + "Transfer-Encoding: gzip\r\n\r\n",
      "HTTP/1.1 204 No Content\r\nContent-Length: 1\r\n\r\nx",
      "HTTP/1.1 204 No Content\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n0\r\n\r\n",
      "HTTP/1.1 101 Switching Protocols\r\n\r\n",
      "HTTP/1.1 100 Continue\r\n\r\n" + head + "Content-Length: 0\r\n\r\n",
    ] {
    with_wire_response(wire) <| transport => {
      let rejected = try {
        ignore(transport.send(@gh.Request::new(verb=Get, path="/api/v1/user")))
        false
      } catch {
        @async.TimeoutError => false
        _ => true
      }
      assert_true(rejected)
    }
  }
}

///|
async test "response metadata keeps duplicate policy and discards cookies and trailers" {
  with_wire_response("HTTP/1.1 205 Reset Content\r\n\r\n", keep_open=true) <| transport => {
    let response = transport.send(@gh.Request::new(verb=Get, path="/api/v1/user"))
    assert_eq(response.status, 205)
    assert_eq(response.body, "")
  }
  with_wire_response("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nabc\r", keep_open=true) <| transport => {
    assert_eq(transport.send(@gh.Request::new(verb=Get, path="/api/v1/user")).body, "abc\r")
  }
  with_wire_response(
    "HTTP/1.1 200 OK\r\nX-Request-Id: first\r\nX-Request-Id: second\r\nSet-Cookie: secret=yes\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nX-Request-Id: trailer\r\nContent-Encoding: gzip\r\n\r\n",
  ) <| transport => {
    let response = transport.send(@gh.Request::new(verb=Get, path="/api/v1/user"))
    assert_eq(response.header("x-request-id"), Some("first, second"))
    assert_eq(response.header("set-cookie"), None)
    assert_eq(response.header("content-encoding"), None)
  }
  for
    wire in [
      "HTTP/1.1 204 No Content\r\n\r\n",
      "HTTP/1.1 205 Reset Content\r\nContent-Length: 0\r\n\r\n",
      "HTTP/1.1 304 Not Modified\r\nContent-Length: 123\r\n\r\n",
      "HTTP/1.0 200 OK\r\n\r\nabc\r",
    ] {
    with_wire_response(wire) <| transport => {
      let response = transport.send(@gh.Request::new(verb=Get, path="/api/v1/user"))
      assert_eq(response.body, if response.status == 200 { "abc\r" } else { "" })
    }
  }
}

///|
async test "bounded framing keeps fixed chunked and close-delimited bodies" {
  for
    wire in [
      "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n月a",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4;ok=yes\r\n月a\r\n0\r\nX-Trailer: ignored\r\n\r\n",
      "HTTP/1.0 200 OK\r\n\r\n月a",
    ] {
    with_wire_response(wire, max_response_bytes=4) <| transport => {
      let response = transport.send(
        @gh.Request::new(verb=Get, path="/api/v1/user"),
      )
      assert_eq(response.status, 200)
      assert_eq(response.body, "月a")
    }
  }
}
