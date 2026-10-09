///|
/// Compose the native adapter, ambient MOONHUB_TOKEN/explicit config loader and
/// optional JSONL file sink. This creates no network connection and writes no
/// credentials. Supplying token overrides environment and file credentials.
pub async fn client(
  base_url~ : String,
  token? : String,
  config_path? : String,
  trace_path? : String,
  timeout_ms? : Int = 30000,
  max_response_bytes? : Int = 8388608,
  read_retry? : @moonhub.ReadRetryPolicy,
) -> Result[@moonhub.Client, @gh.ApiError] {
  if trace_path is Some(path) && (path.is_empty() || path == "-") {
    return Err(
      @gh.InvalidRequest(message="trace requires an explicit file path"),
    )
  }
  let explicit = token
  let credential = match @auth.load_token(base_url~, explicit?, config_path?) {
    Ok(credential) => credential
    Err(err) => return Err(err)
  }
  let transport = @transport.native_transport(
    base_url~,
    timeout_ms~,
    max_response_bytes~,
  ) catch {
    err if @async.is_cancellation_error(err) => raise err
    _ =>
      return Err(
        @gh.InvalidRequest(message="invalid native transport configuration"),
      )
  }
  let sink : (async (@gh.TraceRecord) -> Unit)? = match trace_path {
    Some(path) => Some(record => @trace.append(path, record))
    None => None
  }
  let token = credential
  let trace = sink
  @moonhub.Client::new(
    config=@moonhub.ClientConfig::new(base_url~),
    transport~,
    token?,
    trace?,
    read_retry?,
  )
}
