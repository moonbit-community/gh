///|
async test "invalid destinations and injected headers fail before connecting" {
  let transport = native_transport(base_url="https://must-not-contact.invalid")
  for
    path in [
      "https://other.invalid/api/v1/user", "//other.invalid/user", "/api/v1/user\r\nInjected: yes",
    ] {
    let invalid = try {
      ignore(transport.send(@gh.Request::new(verb=Get, path~)))
      false
    } catch {
      NativeTransportFailure::InvalidRequest => true
      _ => false
    }
    assert_true(invalid)
  }
  for
    headers in [
      [("Authorization", "Bearer secret\r\nX-Injected: yes")],
      [("Host", "other.invalid")],
      [("Content-Length", "123")],
      [("Authorization", "Bearer one"), ("authorization", "Bearer two")],
    ] {
    let invalid = try {
      ignore(
        transport.send(
          @gh.Request::new(verb=Get, path="/api/v1/user", headers~),
        ),
      )
      false
    } catch {
      NativeTransportFailure::InvalidRequest => true
      _ => false
    }
    assert_true(invalid)
  }
}
