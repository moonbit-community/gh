///|
/// Matches cli/cli v2.102.0 pkg/cmd/config/clear-cache. Removal uses lstat
/// semantics for the root, so a symlink is unlinked without following it.
async fn github_clear_cache(
  args : Array[String],
  cache_dir? : String,
  format_context? : @github_cli.FormatContext,
) -> @github_cli.Output {
  let context = format_context.unwrap_or_else(process_format_context)
  let mut operands = 0
  let mut literal = false
  let mut help = false
  for arg in args {
    if literal {
      operands += 1
    } else if arg == "--" {
      literal = true
    } else if arg is ("--help" | "-h") {
      help = true
    } else if arg.has_prefix("-") && arg != "-" {
      let diagnostic = if arg.has_prefix("--") {
        "unknown flag: " + arg.split("=").next().unwrap_or(arg).to_owned()
      } else {
        "unknown shorthand flag: '" + arg[1:2].to_owned() + "' in " + arg
      }
      return local_error(
        diagnostic + "\n\nUsage:  gh config clear-cache [flags]",
      )
    } else {
      operands += 1
    }
  }
  if help {
    return @github_cli.success(stdout=clear_cache_help(context))
  }
  if operands != 0 {
    return local_error("accepts 0 arg(s), received " + operands.to_string())
  }
  let directory = cache_dir.unwrap_or_else(() => api_cache_root().unwrap())
  try {
    if @fs.kind(directory, follow_symlink=false) == @fs.Directory {
      @fs.rmdir(directory, recursive=true)
    } else {
      @fs.remove(directory)
    }
  } catch {
    @os_error.OSError(_) as error if error.is_ENOENT() => ()
    @os_error.OSError(_) as error if error.is_EACCES() =>
      return local_error("unlinkat " + directory + ": permission denied")
    error if @async.is_being_cancelled() => raise error
    _ => return local_error("failed to clear GitHub CLI cache: " + directory)
  }
  // Embedders can execute several commands in one process. Clearing only the
  // disk cache would leave api --cache serving the deleted response in memory.
  api_cache_memory.clear()
  @github_cli.success(
    stdout=@github_cli.actions_success_icon(context) + " Cleared the cache\n",
  )
}

///|
fn clear_cache_help(context : @github_cli.FormatContext) -> String {
  fn heading(text : String) -> String {
    if context.color {
      "\u001b[0;1;39m" + text + "\u001b[0m"
    } else {
      text
    }
  }
  "Clear the cli cache\n\n" +
  heading("USAGE") +
  "\n  gh config clear-cache [flags]\n\n" +
  heading("INHERITED FLAGS") +
  "\n  --help   Show help for command\n\n" +
  heading("EXAMPLES") +
  "\n  # Clear the cli cache\n  $ gh config clear-cache\n\n" +
  heading("LEARN MORE") +
  "\n  Use `gh <command> <subcommand> --help` for more information about a command.\n" +
  "  Read the manual at https://cli.github.com/manual\n" +
  "  Learn about exit codes using `gh help exit-codes`\n" +
  "  Learn about accessibility experiences using `gh help accessibility`\n\n"
}
