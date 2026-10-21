///|
async test "OAuth failure diagnostics classify stages without exposing secret responses or transport errors" {
  for
    (reason, status, body) in [
      ("http-503", 503, b"private-access-token"),
      ("invalid-json", 200, b"private-device-code"),
      ("transport-failure", 0, b""),
      ("response-too-large", 200, Bytes::make(65537, 65)),
    ] {
    let events : Array[String] = []
    let transport = @gh.RawTransport::new(origin="https://github.com", send=_ => {
      if status == 0 {
        fail("private-token in transport exception")
      }
      @gh.RawHttpResponse::new(status~, body~)
    })
    let result = oauth_post(
      transport,
      "/login/oauth/access_token",
      [("device_code", "private-code"), ("client_secret", "private-secret")],
      stage=DevicePoll,
      observe=(stage, failure) => {
        events.push(oauth_diagnostic_message(stage, failure))
      },
    )
    assert_eq(result, Err(OAuthError::Failed))
    assert_eq(events, ["OAuth diagnostic: device-poll / " + reason + "\n"])
  }
}
