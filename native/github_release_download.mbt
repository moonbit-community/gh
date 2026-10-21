///|
fn release_download_exists_error(path : String) -> @github_cli.Output {
  actions_failure(
    path +
    " already exists (use `--clobber` to overwrite file or `--skip-existing` to skip file)",
  )
}

///|
fn release_download_target(
  options : @github_cli.ReleaseDownloadOptions,
  name : String,
) -> String {
  if !options.output.is_empty() {
    options.output
  } else if options.directory == "." {
    name
  } else {
    options.directory + "/" + name
  }
}

///|
async fn release_download_parent(path : String) -> Unit {
  if path.rev_split_once("/") is Some((parent, _)) && !parent.is_empty() {
    @fs.mkdir(
      parent.to_owned(),
      recursive=true,
      allow_exist=true,
      permission=0o755,
    )
  }
}

///|
async fn execute_release_download_command(
  options : @github_cli.BusinessOptions,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
) -> @github_cli.Output {
  let parsed = match @github_cli.parse_release_download(options) {
    Ok(value) => value
    Err(error) => return error
  }
  guard repository is Some(repo) else {
    return actions_failure("a repository is required")
  }
  let metadata = match
    @operations.release_download_metadata(client, repo.full_name(), parsed.tag) {
    Ok(value) => value
    Err(error) => return actions_api_failure(error, "")
  }
  if !parsed.archive.is_empty() {
    return execute_release_archive(parsed, metadata, client, repo)
  }
  let selected = metadata.assets.filter(asset => {
    parsed.patterns.is_empty() ||
    parsed.patterns.any(pattern => {
      @github_cli.download_name_matches(asset.name, pattern)
    })
  })
  guard !selected.is_empty() else {
    return actions_failure(
      if metadata.assets.is_empty() {
        "no assets to download"
      } else {
        "no assets match the file pattern"
      },
    )
  }
  if selected.length() > 1 && !parsed.output.is_empty() {
    return actions_failure(
      "unable to write more than one asset with `--output`, got " +
      selected.length().to_string() +
      " assets",
    )
  }
  for asset in selected {
    guard !parsed.output.is_empty() || business_asset_filename(asset.name) else {
      return actions_failure("release asset has an invalid filename")
    }
    let target = release_download_target(parsed, asset.name)
    if target != "-" && @fs.exists(target) {
      if parsed.skip_existing {
        continue
      }
      if !parsed.clobber {
        return release_download_exists_error(target)
      }
    }
    if target == "-" {
      let bytes = @buffer.Buffer()
      match
        client.download_release_asset_into(
          asset.path,
          @gh.RawResponseSink::new(headers=_ => true, chunk=chunk => {
            bytes.write_bytes(chunk)
          }),
        ) {
        Err(error) => return actions_api_failure(error, "")
        Ok(result) if !result.complete() =>
          return actions_failure("incomplete release asset")
        Ok(_) =>
          return release_download_stdout(bytes.to_bytes(), parsed.allow_escapes)
      }
    }
    let mut download_error : @github.GitHubError? = None
    try {
      release_download_parent(target)
      let result = @download.to_file(
        target,
        sink => {
          match client.download_release_asset_into(asset.path, sink) {
            Ok(value) => value
            Err(error) => {
              download_error = Some(error)
              fail("asset download failed")
            }
          }
        },
        replace=parsed.clobber,
        permission=0o644,
      )
      guard result.complete() else { fail("incomplete release asset") }
    } catch {
      error if @async.is_being_cancelled() => raise error
      _ =>
        return match download_error {
          Some(error) => actions_api_failure(error, "")
          None => actions_failure("cannot write release asset " + target)
        }
    }
  }
  @github_cli.success(stdout="")
}

///|
fn release_download_stdout(
  bytes : Bytes,
  allow_escapes : Bool,
) -> @github_cli.Output {
  if !allow_escapes {
    let sample = bytes[:bytes.length().min(512)]
    let binary = sample
      .iter()
      .any(byte => {
        byte <= 0x08 ||
        byte == 0x0B ||
        byte is (0x0E..<=0x1A) ||
        byte is (0x1C..<=0x1F)
      })
    let terminal = @env.get_env_var("GH_FORCE_TTY").map_or(
      @tty.isatty(@stdio.stdout) catch {
        _ => false
      },
      value => !value.is_empty(),
    )
    if binary && terminal {
      return actions_failure(
        "refusing to output binary content (application/octet-stream) to the terminal; use `--output` to save it to a file, or pass --allow-escape-sequences to output it anyway",
      )
    }
    if !binary && bytes.iter().any(byte => byte == 0x1B) {
      return actions_failure(
        "the asset contains terminal escape sequences; use `--output` to save it to a file, or pass --allow-escape-sequences to output it anyway",
      )
    }
  }
  @github_cli.Output::from_bytes(bytes)
}

///|
async fn execute_release_archive(
  options : @github_cli.ReleaseDownloadOptions,
  metadata : @operations.ReleaseDownloadMetadata,
  client : @github.Client,
  repository : @github_cli.RepositoryContext,
) -> @github_cli.Output {
  let url = if options.archive == "zip" {
    metadata.zip_url
  } else {
    metadata.tar_url
  }
  if url.is_empty() {
    return actions_failure(
      "release " +
      Json(metadata.name).stringify() +
      " with tag " +
      Json(metadata.tag).stringify() +
      ", does not have a " +
      Json(options.archive).stringify() +
      " archive asset." +
      (if metadata.draft {
        " Most likely, this is because it is a draft."
      } else {
        ""
      }),
    )
  }
  let route = "/repos/" +
    repository.full_name() +
    (if options.archive == "zip" { "/zipball/" } else { "/tarball/" })
  guard url.strip_prefix(client.config.base_url()) is Some(path) &&
    path.has_prefix(route) &&
    path.length() > route.length() else {
    return actions_failure("archive download left its repository")
  }
  // Archive names arrive in response headers. Spooling keeps the network body
  // bounded in memory and validates the name before creating any destination.
  let directory = @fs.tmpdir(prefix="gh-release-archive-")
  defer @fs.rmdir(directory, recursive=true)
  let stage = directory + "/archive"
  let mut download_error : @github.GitHubError? = None
  let result = @download.to_file(stage, sink => {
    match client.download_release_archive_into(path.to_owned(), sink) {
      Ok(value) => value
      Err(error) => {
        download_error = Some(error)
        fail("archive download failed")
      }
    }
  }) catch {
    error if @async.is_being_cancelled() => raise error
    _ =>
      return match download_error {
        Some(error) => actions_api_failure(error, "")
        None => actions_failure("cannot receive release archive")
      }
  }
  let name = match
    release_archive_filename(
      result.head().header("content-disposition").unwrap_or(""),
    ) {
    Ok(name) => name
    Err(error) => return actions_failure(error)
  }
  let target = release_download_target(options, name)
  if target == "-" {
    return release_download_stdout(
      @fs.read_file(stage).binary(),
      options.allow_escapes,
    )
  }
  if @fs.exists(target) {
    if options.skip_existing {
      return @github_cli.success(stdout="")
    }
    if !options.clobber {
      return release_download_exists_error(target)
    }
  }
  try {
    release_download_parent(target)
    ignore(
      @download.to_file(
        target,
        sink => {
          let head = @gh.RawResponseHead::new(status=200)
          guard sink.headers(head) else {
            fail("archive destination rejected headers")
          }
          let file = @fs.open(stage, mode=ReadOnly)
          defer file.close()
          let mut count = 0L
          while file.read_some(max_len=65536) is Some(bytes) {
            sink.chunk(bytes)
            count += bytes.length().to_int64()
          }
          @gh.RawDownloadResult::new(head~, bytes_received=count, complete=true)
        },
        replace=options.clobber,
        permission=0o644,
      ),
    )
  } catch {
    error if @async.is_being_cancelled() => raise error
    _ => return actions_failure("cannot write release archive " + target)
  }
  @github_cli.success(stdout="")
}

///|
fn release_archive_filename(header : String) -> Result[String, String] {
  if header.trim().is_empty() {
    return Err("unable to parse file name of archive: mime: no media type")
  }
  // MIME quoted strings may contain semicolons and backslash escapes.
  let parts : Array[String] = []
  let part = StringBuilder()
  let mut quoted = false
  let mut escaped = false
  for ch in header {
    if escaped {
      part.write_char(ch)
      escaped = false
    } else if quoted && ch == '\\' {
      escaped = true
    } else if ch == '"' {
      quoted = !quoted
    } else if ch == ';' && !quoted {
      parts.push(part.to_string())
      part.reset()
    } else {
      part.write_char(ch)
    }
  }
  if quoted || escaped {
    return Err(
      "unable to parse file name of archive: mime: invalid media parameter",
    )
  }
  parts.push(part.to_string())
  let parameters : Map[String, String] = Map([])
  for index in 1..<parts.length() {
    guard parts[index].trim().split_once("=") is Some((key, value)) else {
      return Err(
        "unable to parse file name of archive: mime: invalid media parameter",
      )
    }
    let key = key.trim().to_owned().to_lower()
    let value = value.trim().to_owned()
    if parameters.contains(key) && parameters[key] != value {
      return Err(
        "unable to parse file name of archive: mime: duplicate parameter name",
      )
    }
    parameters[key] = value
  }
  let name = match parameters.get("filename*") {
    Some(value) => {
      let parts = value.split("'").collect()
      guard parts.length() == 3 && parts[0].equal_ignore_ascii_case("utf-8") else {
        return Err("unable to determine file name of archive")
      }
      @percent.decode(parts[2].to_owned()) catch {
        _ => return Err("unable to determine file name of archive")
      }
    }
    None => parameters.get("filename").unwrap_or("")
  }
  let name = name.split("/").last().unwrap_or("").to_owned()
  if !business_asset_filename(name) {
    return Err("unable to determine file name of archive")
  }
  Ok(name)
}
