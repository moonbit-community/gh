///|
/// Closed, non-secret diagnostics for a failed acceptance authorization. Never
/// pass response bodies, request URLs, OAuth codes or exception text here.
priv enum OAuthStage {
  DeviceCode
  DevicePoll
  WebExchange
}

///|
priv enum OAuthFailure {
  Transport
  HttpStatus(Int32)
  ResponseTooLarge
  InvalidJson
  ProviderError
  InvalidTokenResponse
}

///|
fn oauth_diagnostic_message(
  stage : OAuthStage,
  failure : OAuthFailure,
) -> String {
  let stage = match stage {
    DeviceCode => "device-code"
    DevicePoll => "device-poll"
    WebExchange => "web-exchange"
  }
  let reason = match failure {
    Transport => "transport-failure"
    HttpStatus(status) => "http-" + status.to_string()
    ResponseTooLarge => "response-too-large"
    InvalidJson => "invalid-json"
    ProviderError => "provider-error"
    InvalidTokenResponse => "invalid-token-response"
  }
  "OAuth diagnostic: " + stage + " / " + reason + "\n"
}

///|
async fn oauth_diagnostic(stage : OAuthStage, failure : OAuthFailure) -> Unit {
  guard @env.get_env_var("GH_TEST_OAUTH_DIAGNOSTICS") == Some("1") else {
    return
  }
  @stdio.stderr.write(oauth_diagnostic_message(stage, failure)) catch {
    error if @async.is_being_cancelled() => raise error
    _ => ()
  }
}
