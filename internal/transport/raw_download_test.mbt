///|
async test "streamed response exceeds API cap with bounded chunks and exact content" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      ignore(conn.read_request())
      conn.send_response(200, "OK")
      let chunk = Bytes::make(65536, b'\xa5')
      for _ in 0..<320 {
        conn.write(chunk)
      }
      conn.end_response()
    }
    let transport = @transport.native_raw_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
      max_response_bytes=1024,
    )
    assert_true(transport.supports_streaming())
    let mut seen_head = false
    let mut total = 0L
    let result = transport.receive(
      @gh.RawRequest::new(verb="GET", path="/large"),
      @gh.RawResponseSink::new(
        headers=head => {
          assert_false(seen_head)
          assert_eq(head.status(), 200)
          seen_head = true
          true
        },
        chunk=bytes => {
          assert_true(seen_head)
          assert_true(bytes.length() <= 8192)
          assert_true(bytes.iter().all(byte => byte == b'\xa5'))
          total += bytes.length().to_int64()
        },
      ),
    )
    assert_eq(total, 20971520L)
    assert_eq(result.bytes_received(), total)
    assert_true(result.complete())
  }
}

///|
async test "buffered API response retains its independent limit" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      ignore(conn.read_request())
      conn.send_response(200, "OK")
      conn..write(Bytes::make(1025, b'x')).end_response()
    }
    let transport = @transport.native_raw_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
      max_response_bytes=1024,
    )
    let rejected = try {
      ignore(transport.send(@gh.RawRequest::new(verb="GET", path="/large")))
      false
    } catch {
      _ => true
    }
    assert_true(rejected)
  }
}

///|
async test "declining redirect body returns metadata without reading payload" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      ignore(conn.read_request())
      conn.send_response(302, "Found", extra_headers={
        "Location": "/destination",
      })
      conn.end_response()
    }
    let transport = @transport.native_raw_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
    )
    let result = transport.receive(
      @gh.RawRequest::new(verb="GET", path="/redirect"),
      @gh.RawResponseSink::new(
        headers=head => {
          assert_eq(head.header("location"), Some("/destination"))
          false
        },
        chunk=_ => fail("declined response delivered body bytes"),
      ),
    )
    assert_eq(result.head().status(), 302)
    assert_eq(result.bytes_received(), 0L)
    assert_false(result.complete())
  }
}

///|
async test "response sink failures propagate rather than reporting a complete file" {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      let (conn, _) = server.accept()
      defer conn.close()
      ignore(conn.read_request())
      conn.send_response(200, "OK")
      conn..write(b"asset").end_response()
    }
    let transport = @transport.native_raw_transport(
      base_url="http://127.0.0.1:\{server.addr.port()}",
    )
    let failed = try {
      ignore(
        transport.receive(
          @gh.RawRequest::new(verb="GET", path="/asset"),
          @gh.RawResponseSink::new(headers=_ => true, chunk=_ => {
            fail("disk rejected write")
          }),
        ),
      )
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  }
}
