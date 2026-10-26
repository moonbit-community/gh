///|
async test "config clear-cache preserves credentials and validates before deleting" {
  let directory = @fs.tmpdir(prefix="gh-clear-cache-")
  defer @fs.rmdir(directory, recursive=true)
  let cache = directory + "/cache"
  @fs.mkdir(cache + "/nested", recursive=true)
  @fs.write_file(cache + "/nested/.hidden", "cached")
  @fs.write_file(directory + "/hosts.yml", "fixture-only-credential")
  for arguments in [["extra"], ["--host", "github.com"], ["--", "--help"]] {
    let result = @native.github_config_command(
      ["clear-cache", ..arguments],
      cache_dir=cache,
      config_dir=directory,
    )
    assert_eq(result.exit_code(), 1)
    assert_eq(@fs.read_file(cache + "/nested/.hidden").text(), "cached")
  }
  let result = @native.github_config_command(
    ["clear-cache"],
    cache_dir=cache,
    config_dir=directory,
    format_context=@github_cli.FormatContext::new(),
  )
  assert_eq(result.exit_code(), 0)
  assert_eq(result.stdout(), "✓ Cleared the cache\n")
  assert_false(@fs.exists(cache))
  assert_eq(
    @fs.read_file(directory + "/hosts.yml").text(),
    "fixture-only-credential",
  )
  assert_eq(
    @native.github_config_command(["clear-cache"], cache_dir=cache).exit_code(),
    0,
  )
  @fs.write_file(cache, "old file")
  assert_eq(
    @native.github_config_command(["clear-cache"], cache_dir=cache).exit_code(),
    0,
  )
  assert_false(@fs.exists(cache))
}

///|
#cfg(not(platform="windows"))
async test "config clear-cache unlinks root and nested symlinks without following targets" {
  let directory = @fs.tmpdir(prefix="gh-clear-cache-links-")
  defer @fs.rmdir(directory, recursive=true)
  let target = directory + "/keep"
  @fs.mkdir(target)
  @fs.write_file(target + "/value", "unrelated")
  let cache = directory + "/cache"
  for nested in [false, true] {
    if nested {
      @fs.mkdir(cache)
      @fs.symlink(target~, cache + "/link")
    } else {
      @fs.symlink(target~, cache)
    }
    let result = @native.github_config_command(["clear-cache"], cache_dir=cache)
    assert_eq(result.exit_code(), 0)
    assert_false(@fs.exists(cache))
    assert_eq(@fs.read_file(target + "/value").text(), "unrelated")
  }
}
