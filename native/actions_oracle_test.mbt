///|
/// Compare SDK/CLI behavior with an actual fixed-oracle capture, including
/// downloaded files and an explicitly isolated log cache.
async fn check_actions_oracle(encoded : String) -> Unit {
  let directory = @fs.tmpdir(prefix="gh-actions-corpus-")
  defer @fs.rmdir(directory, recursive=true)
  let case = @json.parse(encoded)
  guard case
    is {
      "args": Array(args),
      "routes": Object(routes),
      "stdout": String(stdout),
      "stderr": String(stderr),
      "exit_code": Number(exit_code, ..),
      "requests": Array(expected_requests),
      "files_hex": Object(expected_files),
      ..
    } else {
    fail("invalid oracle case")
  }
  let seen : Array[Json] = []
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.com"),
      transport=@github.Transport::new(send=request => {
        seen.push(Json(request.path()))
        guard routes.get(request.path()) is Some(route) else {
          fail("unexpected candidate request: " + request.path())
        }
        let status = match route {
          { "status": Number(status, ..), .. } => status.to_int()
          _ => 200
        }
        let headers : Array[(String, String)] = []
        if route is { "headers": Object(fields), .. } {
          for key, value in fields {
            guard value is String(value) else { fail("header") }
            headers.push(
              (
                key,
                value.replace_all(
                  old="http://api.github.localhost",
                  new="https://api.github.com",
                ),
              ),
            )
          }
        }
        let body = match route {
          { "json": value, .. } =>
            @utf8.encode(
              value
              .stringify()
              .replace_all(
                old="http://api.github.localhost",
                new="https://api.github.com",
              ),
            )
          { "text": String(value), .. } => @utf8.encode(value)
          { "zip": Array(files), .. } => {
            let archive = @zip.Archive()
            for file in files {
              guard file is { "name": String(name), "text": String(text), .. } else {
                fail("ZIP fixture")
              }
              archive.add(name, @utf8.encode(text), compression=Deflate)
            }
            @zip.write(archive)
          }
          _ => b""
        }
        Ok(@github.RawResponse::new(status~, headers~, body~))
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  let arguments = args.map(arg => {
    match arg {
      String(arg) => arg
      _ => fail("argument")
    }
  })
  for i in 1..<arguments.length() {
    if arguments[i - 1] == "-D" {
      arguments[i] = directory + "/" + arguments[i]
    }
  }
  guard @github_cli.parse(arguments) is @github_cli.Business(options) else {
    fail("parse")
  }
  guard @github_cli.RepositoryContext::parse("acme/widgets") is Ok(repository) else {
    fail("repository")
  }
  let result = @native.execute_github_business(
    options,
    client~,
    repository~,
    base_url="https://api.github.com",
    cache_directory=directory + "/.cache/gh",
  )
  assert_eq(result.stdout(), stdout)
  assert_eq(result.stderr(), stderr)
  assert_eq(result.exit_code(), exit_code.to_int())
  assert_eq(seen, expected_requests)
  let expected_downloads = expected_files.length()
  let mut actual_downloads = 0
  @fs.walk(
    directory,
    (path, names) => {
      for name in names {
        let full = path + "/" + name
        if @fs.kind(full, follow_symlink=false) == @fs.Regular {
          actual_downloads += 1
          let relative = full[directory.length() + 1:].to_owned()
          guard expected_files.get(relative) is Some(String(hex)) else {
            fail("unexpected downloaded file")
          }
          assert_eq(
            @crypto.bytes_to_hex_string(@fs.read_file(full).binary()),
            hex,
          )
        }
      }
    },
    max_concurrency=1,
  )
  assert_eq(actual_downloads, expected_downloads)
  if case is { "directories": Array(directories), .. } {
    for item in directories {
      guard item is String(path) else { fail("directory") }
      assert_eq(
        @fs.kind(directory + "/" + path, follow_symlink=false),
        @fs.Directory,
      )
    }
  }
}
