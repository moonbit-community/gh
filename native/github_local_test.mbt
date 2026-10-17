///|
async test "config defaults and diagnostics match isolated gh v2.102.0 oracle" {
  let directory = @fs.tmpdir(prefix="gh-local-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  let output = @native.github_config_command(["list"], config_dir=directory)
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stderr(), "")
  assert_eq(
    output.stdout(),
    "api_host=\ngit_protocol=https\neditor=\nprompt=enabled\nprefer_editor_prompt=disabled\npager=\nhttp_unix_socket=\nbrowser=\nclipboard=enabled\ncolor_labels=disabled\naccessible_colors=disabled\naccessible_prompter=disabled\nspinner=enabled\ntelemetry=enabled\n",
  )
  assert_eq(
    @native.github_config_command(["get", "editor"], config_dir=directory).stdout(),
    "",
  )
  let missing = @native.github_config_command(
    ["get", "missing"],
    config_dir=directory,
  )
  assert_eq(missing.exit_code(), 1)
  assert_eq(missing.stderr(), "could not find key \"missing\"\n")
  let invalid = @native.github_config_command(
    ["set", "git_protocol", "bad"],
    config_dir=directory,
  )
  assert_eq(invalid.exit_code(), 1)
  assert_eq(
    invalid.stderr(),
    "failed to set \"git_protocol\" to \"bad\": valid values are 'https', 'ssh'\n",
  )
}

///|
async test "config persists globals and host overrides while preserving credentials" {
  let directory = @fs.tmpdir(prefix="gh-local-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(
    directory + "/hosts.yml",
    "ghe.example:\n  user: fixture\n  oauth_token: fixture-only-secret\n  users:\n    fixture:\n      oauth_token: fixture-account-secret\n",
  )
  let unknown = @native.github_config_command(
    ["set", "custom", "yes"],
    config_dir=directory,
  )
  assert_eq(
    unknown.stderr(),
    "! warning: 'custom' is not a known configuration key\n",
  )
  assert_eq(
    @native.github_config_command(["get", "custom"], config_dir=directory).stdout(),
    "yes\n",
  )
  assert_eq(
    @native.github_config_command(
      ["set", "editor", "code --wait"],
      config_dir=directory,
    ).exit_code(),
    0,
  )
  assert_eq(
    @native.github_config_command(
      ["set", "git_protocol", "ssh", "--host", "ghe.example"],
      config_dir=directory,
    ).exit_code(),
    0,
  )
  assert_eq(
    @native.github_config_command(
      ["get", "git_protocol", "--host=ghe.example"],
      config_dir=directory,
    ).stdout(),
    "ssh\n",
  )
  assert_eq(
    @native.github_config_command(["get", "git_protocol"], config_dir=directory).stdout(),
    "https\n",
  )
  assert_eq(
    @native.github_config_command(
      ["get", "editor", "-h", "ghe.example"],
      config_dir=directory,
    ).stdout(),
    "code --wait\n",
  )
  let source = @fs.read_file(directory + "/hosts.yml").text()
  guard @native.resolve_github_auth_source(
      @github_auth.Environment::new(gh_host="ghe.example"),
      source,
    )
    is Ok(config) else {
    fail("credentials were not preserved")
  }
  assert_eq(config.token(), Some("fixture-only-secret"))
  let denied = @native.github_config_command(
    ["get", "oauth_token", "--host", "ghe.example"],
    config_dir=directory,
  )
  assert_eq(denied.exit_code(), 1)
  assert_false(denied.stderr().contains("fixture-only-secret"))
}

///|
async test "alias set list delete and clobber match local oracle" {
  let directory = @fs.tmpdir(prefix="gh-alias-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  assert_eq(
    @native.github_alias_command(["list"], config_dir=directory).stdout(),
    "co: pr checkout\n",
  )
  assert_eq(
    @native.github_alias_command(
      ["set", "zz", "issue list"],
      config_dir=directory,
    ).exit_code(),
    0,
  )
  let duplicate = @native.github_alias_command(
    ["set", "zz", "repo view"],
    config_dir=directory,
  )
  assert_eq(duplicate.exit_code(), 1)
  assert_eq(
    duplicate.stderr(),
    "X Could not create alias zz: name already taken, use the --clobber flag to overwrite it\n",
  )
  assert_eq(
    @native.github_alias_command(
      ["set", "zz", "repo view", "--clobber"],
      config_dir=directory,
    ).exit_code(),
    0,
  )
  assert_eq(
    @native.github_alias_command(
      ["set", "xx", "printf hi", "--shell"],
      config_dir=directory,
    ).exit_code(),
    0,
  )
  assert_eq(
    @native.github_alias_command(["list"], config_dir=directory).stdout(),
    "co: pr checkout\nxx: '!printf hi'\nzz: repo view\n",
  )
  assert_eq(
    @native.github_alias_command(["delete", "missing"], config_dir=directory).stderr(),
    "no such alias missing\n",
  )
  assert_eq(
    @native.github_alias_command(["delete", "zz"], config_dir=directory).exit_code(),
    0,
  )
  assert_eq(
    @native.github_alias_command(["delete", "--all"], config_dir=directory).exit_code(),
    0,
  )
  assert_eq(
    @native.github_alias_command(["list"], config_dir=directory).stdout(),
    "",
  )
}

///|
async test "alias import and stdin preserve existing config and expansions" {
  let directory = @fs.tmpdir(prefix="gh-alias-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(
    directory + "/config.yml",
    "editor: vim\npager:\naliases:\n  xx: repo view\n",
  )
  assert_eq(
    @native.github_alias_command(
      ["set", "aa", "-"],
      config_dir=directory,
      input="issue list\n",
    ).exit_code(),
    0,
  )
  assert_eq(
    @native.github_alias_command(
      ["import", "-"],
      config_dir=directory,
      input="xx: issue list\nzz: repo view\n",
    ).exit_code(),
    0,
  )
  assert_eq(
    @native.github_alias_command(["list"], config_dir=directory).stdout(),
    "aa: issue list\nxx: repo view\nzz: repo view\n",
  )
  assert_eq(
    @native.github_alias_command(
      ["import", "-", "--clobber"],
      config_dir=directory,
      input="xx: issue list\n",
    ).exit_code(),
    0,
  )
  assert_eq(
    @native.github_config_command(["get", "editor"], config_dir=directory).stdout(),
    "vim\n",
  )
  assert_eq(
    @native.github_config_command(["get", "pager"], config_dir=directory).stdout(),
    "",
  )
  @fs.write_file(directory + "/import.yml", "filealias: repo view\n")
  assert_eq(
    @native.github_alias_command(
      ["import", directory + "/import.yml"],
      config_dir=directory,
    ).exit_code(),
    0,
  )
  assert_true(
    @native.github_alias_command(["list"], config_dir=directory)
    .stdout()
    .contains("filealias: repo view\n"),
  )
}

///|
async test "malformed local files never get overwritten" {
  let directory = @fs.tmpdir(prefix="gh-local-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  let source = "editor: one\neditor: two\n"
  @fs.write_file(directory + "/config.yml", source)
  assert_eq(
    @native.github_config_command(
      ["set", "editor", "three"],
      config_dir=directory,
    ).exit_code(),
    1,
  )
  assert_eq(@fs.read_file(directory + "/config.yml").text(), source)
  assert_eq(
    @native.github_alias_command(
      ["set", "alias", "issue list"],
      config_dir=directory,
    ).exit_code(),
    1,
  )
  assert_eq(@fs.read_file(directory + "/config.yml").text(), source)
}
