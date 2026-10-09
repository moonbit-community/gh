///|
/// Load a credential from explicit input, MOONHUB_TOKEN, or an explicit file.
/// No default config location or persistent writes are introduced here.
/// File contents, paths, OS errors, and token values never enter diagnostics.
pub async fn load_token(
  base_url~ : String,
  explicit? : String,
  config_path? : String,
) -> Result[@moonhub.Token?, @gh.ApiError] {
  let environment = if explicit is Some(_) {
    None
  } else {
    @env.get_env_var("MOONHUB_TOKEN")
  }
  load_from_inputs(base_url~, explicit?, environment?, config_path?)
}

///|
async fn load_from_inputs(
  base_url~ : String,
  explicit? : String,
  environment? : String,
  config_path? : String,
) -> Result[@moonhub.Token?, @gh.ApiError] {
  if explicit is Some(_) {
    return @moonhub.resolve_token(base_url~, explicit?)
  }
  if environment is Some(_) {
    return @moonhub.resolve_token(base_url~, environment?)
  }
  let path = match config_path {
    None => return @moonhub.resolve_token(base_url~)
    Some("") =>
      return Err(@gh.InvalidRequest(message="empty MoonHub config path"))
    Some(path) => path
  }
  // Validate destination before reading any credential file.
  match @gh.normalize_origin(base_url) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let source = try {
    if @fs.kind(path) != @fs.Regular {
      return Err(
        @gh.InvalidRequest(message="MoonHub config must be a regular file"),
      )
    }
    let file = @fs.open(path, mode=ReadOnly)
    defer file.close()
    let size = file.size()
    if size > 65536L {
      return Err(@gh.InvalidRequest(message="MoonHub config exceeds 64 KiB"))
    }
    let bytes = file.read_exactly_at(size.to_int(), position=0L)
    @utf8.decode(bytes)
  } catch {
    err if @async.is_cancellation_error(err) => raise err
    _ => return Err(@gh.InvalidRequest(message="cannot read MoonHub config"))
  }
  @moonhub.resolve_token(base_url~, config_json=source)
}
