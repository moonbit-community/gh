///|
async test "file loader resolves only the requested origin" {
  let directory = @fs.tmpdir(prefix="gh-auth")
  defer @fs.rmdir(directory, recursive=true)
  let path = directory + "/config.json"
  @fs.write_file(
    path,
    (
      #|{"version":1,"hosts":{"https://moonhub.example":"stored-token"}}
    ),
    permission=0o600,
  )
  match load_from_inputs(base_url="https://moonhub.example", config_path=path) {
    Ok(Some(token)) => {
      assert_eq(token.authorization(), "Bearer stored-token")
      assert_true(token.source() is @moonhub.Config)
    }
    _ => fail("config credential was not loaded")
  }
  assert_true(
    load_from_inputs(base_url="https://other.example", config_path=path)
    is Ok(None),
  )
}

///|
async test "higher priority credentials skip file reads and do not fall back" {
  let directory = @fs.tmpdir(prefix="gh-auth")
  defer @fs.rmdir(directory, recursive=true)
  let nonexistent = directory + "/missing-secret-name.json"
  assert_true(
    load_from_inputs(
      base_url="https://moonhub.example",
      explicit="provided-token",
      environment="",
      config_path=nonexistent,
    )
    is Ok(Some(_)),
  )
  assert_true(
    load_from_inputs(
      base_url="https://moonhub.example",
      environment="provided-token",
      config_path=nonexistent,
    )
    is Ok(Some(_)),
  )
  assert_true(
    load_from_inputs(
      base_url="https://moonhub.example",
      environment="",
      config_path=nonexistent,
    )
    is Err(@gh.InvalidRequest(message="invalid MOONHUB_TOKEN")),
  )
  assert_true(
    load_from_inputs(
      base_url="https://moonhub.example",
      config_path=nonexistent,
    )
    is Err(@gh.InvalidRequest(message="cannot read MoonHub config")),
  )
}

///|
async test "file loader rejects directories malformed UTF-8 and oversized config" {
  let directory = @fs.tmpdir(prefix="gh-auth")
  defer @fs.rmdir(directory, recursive=true)
  assert_true(
    load_from_inputs(base_url="https://moonhub.example", config_path=directory)
    is Err(@gh.InvalidRequest(message="MoonHub config must be a regular file")),
  )
  let path = directory + "/config.json"
  @fs.write_file(path, b"\xff", permission=0o600)
  assert_true(
    load_from_inputs(base_url="https://moonhub.example", config_path=path)
    is Err(@gh.InvalidRequest(message="cannot read MoonHub config")),
  )
  @fs.write_file(path, Bytes::make(65537, 32), permission=0o600)
  assert_true(
    load_from_inputs(base_url="https://moonhub.example", config_path=path)
    is Err(@gh.InvalidRequest(message="MoonHub config exceeds 64 KiB")),
  )
}
