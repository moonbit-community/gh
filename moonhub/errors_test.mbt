///|
test "HTTP status categories survive malformed or untrusted error bodies" {
  for
    (status, expected) in [
      (400, "invalid_request"),
      (401, "unauthorized"),
      (403, "forbidden"),
      (404, "not_found"),
      (409, "conflict"),
      (412, "conflict"),
      (422, "invalid_request"),
      (429, "rate_limited"),
      (503, "server"),
      (302, "unexpected_status"),
    ] {
    let result = @moonhub.decode_response(
      @gh.Response::new(status~, body="<html>private-secret</html>"),
    )
    match result {
      Err(err) => {
        assert_eq(err.kind.code(), expected)
        assert_eq(err.status, Some(status))
        assert_true(err.code is None)
      }
      Ok(_) => fail("error status accepted")
    }
  }
  let body =
    #|{"version":1,"error":{"code":"unauthorized","message":"token=private-secret"},"request_id":"body-id"}
  match
    @moonhub.decode_response(
      @gh.Response::new(status=403, body~, headers=[
        ("X-Request-ID", "header-id"),
      ]),
    ) {
    Err(err) => {
      assert_true(err.kind is @gh.Forbidden)
      assert_eq(err.code, Some("unauthorized"))
      assert_eq(err.request_id, Some("header-id"))
    }
    _ => fail("error envelope was not decoded")
  }
}

///|
test "unknown versions and unsafe correlation IDs are not exposed" {
  let unknown_version =
    #|{"version":2,"error":{"code":"not_found"},"request_id":"body-id"}
  let echoed_secret =
    #|{"version":1,"error":{"code":"private-secret"},"request_id":"private-secret"}
  for body in [unknown_version, echoed_secret] {
    match
      @moonhub.decode_response(@gh.Response::new(status=404, body~), secrets=[
        "private-secret",
      ]) {
      Err(err) => {
        assert_true(err.code is None)
        assert_true(err.request_id is None)
      }
      _ => fail("expected HTTP failure")
    }
  }
  let response = @gh.Response::new(status=204, body="")
  assert_true(@moonhub.decode_response(response) is Ok(_))
}
