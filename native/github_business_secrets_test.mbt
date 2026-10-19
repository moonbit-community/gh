///|
async test "secret set fetches public key and sends sealed value" {
  let mut calls = 0
  let mut put_body : Json? = None
  let transport = @github.Transport::new(send=request => {
    calls += 1
    if calls == 1 {
      assert_eq(request.verb(), "GET")
      assert_eq(
        request.path(),
        "/repos/acme/widgets/actions/secrets/public-key",
      )
      Ok(
        @github.RawResponse::new(
          status=200,
          body=@utf8.encode(
            "{\"key_id\":\"fixture-key\",\"key\":\"j0DFrbaPJWJK5bIU6nZ6bslNgp09e14a0bpvPiE4KF8=\"}",
          ),
        ),
      )
    } else {
      assert_eq(calls, 2)
      assert_eq(request.verb(), "PUT")
      assert_eq(
        request.path(),
        "/repos/acme/widgets/actions/secrets/CODEX_SECRET",
      )
      guard request.body() is Some(body) else { fail("secret body missing") }
      let parsed : Json = @json.parse(@utf8.decode(body)) catch {
        _ => fail("secret body is not JSON")
      }
      put_body = Some(parsed)
      Ok(@github.RawResponse::new(status=204, body=b""))
    }
  })
  let client = match
    @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.example"),
      transport~,
    ) {
    Ok(value) => value
    Err(_) => fail("fixture client setup failed")
  }
  let options = match
    @github_cli.parse([
      "secret", "set", "CODEX_SECRET", "-R", "acme/widgets", "--body", "fixture-secret",
    ]) {
    @github_cli.Business(value) => value
    _ => fail("expected business invocation")
  }
  let output = @native.execute_github_business(
    options,
    client~,
    base_url="https://api.github.example",
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stdout(), "")
  assert_eq(calls, 2)
  let body = match put_body {
    Some(value) => value
    None => fail("secret PUT was not observed")
  }
  match body {
    Object(fields) => {
      assert_eq(fields.get("key_id"), Some(Json::string("fixture-key")))
      match fields.get("encrypted_value") {
        Some(String(value)) => {
          assert_false(value.is_empty())
          assert_false(value.contains("fixture-secret"))
          let encrypted = @base64.decode(value) catch {
            _ => fail("encrypted value is not base64")
          }
          assert_eq(encrypted.length(), 32 + 16 + "fixture-secret".length())
        }
        _ => fail("encrypted value missing")
      }
    }
    _ => fail("secret body is not an object")
  }
}
