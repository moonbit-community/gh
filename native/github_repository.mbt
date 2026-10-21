///|
/// Resolve an explicit repository, GH_REPO, or a local git remote. Git is
/// invoked with an argument array and captured output; no shell is involved.
/// API callers may disable gh-resolved handling to use gh's BaseRepo policy.
pub async fn resolve_repository_context(
  repo? : String,
  need_branch~ : Bool = false,
  respect_resolved~ : Bool = true,
) -> Result[@github_cli.RepositoryContext, @github_cli.Output] {
  resolve_repository_with(
    repo?,
    gh_repo?=@env.get_env_var("GH_REPO"),
    gh_host?=@env.get_env_var("GH_HOST"),
    need_branch~,
    respect_resolved~,
    run=repository_git,
  )
}

///|
/// Resolve a branch without requiring any remote. This supports API inputs
/// that use {branch} alone. GH_REPO intentionally disables local branch use.
pub async fn resolve_current_branch() -> Result[String, @github_cli.Output] {
  repository_current_branch(
    gh_repo?=@env.get_env_var("GH_REPO"),
    run=repository_git,
  )
}

///|
priv struct RepositoryGitResult {
  code : Int32
  stdout : String
}

///|
priv struct RepositoryRemote {
  name : String
  repository : @github_cli.RepositoryContext
}

///|
async fn resolve_repository_with(
  repo? : String,
  gh_repo? : String,
  gh_host? : String,
  need_branch~ : Bool = false,
  respect_resolved~ : Bool = true,
  run~ : async (Array[String]) -> RepositoryGitResult,
) -> Result[@github_cli.RepositoryContext, @github_cli.Output] {
  let default_host = gh_host.filter(x => !x.is_empty()).unwrap_or("github.com")
  if need_branch && gh_repo is Some(value) && !value.is_empty() {
    return Err(
      @github_cli.failure(
        message="unable to determine current branch when GH_REPO is set",
      ),
    )
  }
  let repo_override = match repo {
    Some(value) => Some(value)
    None => gh_repo.filter(x => !x.is_empty())
  }
  let selected = match repo_override {
    Some(value) =>
      match @github_cli.RepositoryContext::parse(value, default_host~) {
        Ok(context) => context
        Err(_) =>
          return Err(
            @github_cli.failure(message="expected the [HOST/]OWNER/REPO format"),
          )
      }
    None => {
      let result = run(["remote", "-v"]) catch {
        error if @async.is_being_cancelled() => raise error
        _ =>
          return Err(@github_cli.failure(message="could not read git remotes"))
      }
      guard result.code == 0 else {
        return Err(
          @github_cli.failure(
            message="not a git repository; use --repo or GH_REPO",
          ),
        )
      }
      let remotes = repository_remotes(result.stdout)
      guard !remotes.is_empty() else {
        return Err(
          @github_cli.failure(
            message="no supported git remote found; use --repo or GH_REPO",
          ),
        )
      }
      let mut configured : @github_cli.RepositoryContext? = None
      if respect_resolved {
        let result = run([
          "config", "--null", "--get-regexp", "^remote\\..*\\.gh-resolved$",
        ]) catch {
          error if @async.is_being_cancelled() => raise error
          _ =>
            return Err(
              @github_cli.failure(
                message="could not read git repository configuration",
              ),
            )
        }
        if result.code != 0 && result.code != 1 {
          return Err(
            @github_cli.failure(
              message="could not read git repository configuration",
            ),
          )
        }
        if result.code == 0 {
          for entry in result.stdout.split("\u0000") {
            guard entry.split_once("\n") is Some((key, value)) else { continue }
            guard key.strip_prefix("remote.") is Some(key) &&
              key.strip_suffix(".gh-resolved") is Some(name) else {
              continue
            }
            for remote in remotes {
              if remote.name == name.to_owned() {
                if value == "base" {
                  configured = Some(remote.repository)
                } else if @github_cli.RepositoryContext::parse(
                    value.to_owned(),
                    default_host=remote.repository.host(),
                  )
                  is Ok(context) {
                  configured = Some(context)
                }
                break
              }
            }
            if configured is Some(_) {
              break
            }
          }
        }
      }
      match configured {
        Some(context) => context
        None => {
          let mut best = remotes[0]
          for remote in remotes {
            if repository_remote_priority(remote.name) <
              repository_remote_priority(best.name) {
              best = remote
            }
          }
          best.repository
        }
      }
    }
  }
  if !need_branch {
    return Ok(selected)
  }
  match repository_current_branch(gh_repo?, run~) {
    Err(output) => Err(output)
    Ok(branch) =>
      match selected.with_branch(branch) {
        Ok(context) => Ok(context)
        Err(_) =>
          Err(
            @github_cli.failure(
              message="could not determine the current branch",
            ),
          )
      }
  }
}

///|
async fn repository_current_branch(
  gh_repo? : String,
  run~ : async (Array[String]) -> RepositoryGitResult,
) -> Result[String, @github_cli.Output] {
  if gh_repo is Some(value) && !value.is_empty() {
    return Err(
      @github_cli.failure(
        message="unable to determine current branch when GH_REPO is set",
      ),
    )
  }
  let result = run(["symbolic-ref", "--quiet", "--short", "HEAD"]) catch {
    error if @async.is_being_cancelled() => raise error
    _ =>
      return Err(
        @github_cli.failure(message="could not determine the current branch"),
      )
  }
  guard result.code == 0 else {
    return Err(
      @github_cli.failure(
        message="could not determine the current branch: not on any branch",
      ),
    )
  }
  let branch = result.stdout.trim().to_owned()
  if branch.is_empty() ||
    branch.length() > 4096 ||
    branch.iter().any(ch => ch.to_int() <= 32 || ch.to_int() == 127) {
    Err(@github_cli.failure(message="could not determine the current branch"))
  } else {
    Ok(branch)
  }
}

///|
fn repository_remotes(output : String) -> Array[RepositoryRemote] {
  let remotes : Array[RepositoryRemote] = []
  for line in output.split("\n") {
    let line = line.strip_suffix("\r").unwrap_or(line)
    guard line.split_once("\t") is Some((name, value)) else { continue }
    guard !name.is_empty() && value.strip_suffix(" (fetch)") is Some(url) else {
      continue
    }
    if remotes.any(remote => remote.name == name.to_owned()) {
      continue
    }
    match @github_cli.RepositoryContext::from_remote(url.to_owned()) {
      Ok(repository) => remotes.push({ name: name.to_owned(), repository, })
      Err(_) => ()
    }
  }
  remotes
}

///|
fn repository_remote_priority(name : String) -> Int32 {
  match name {
    "upstream" => 0
    "github" => 1
    "origin" => 2
    _ => 3
  }
}

///|
priv suberror RepositoryProcessFailure {
  OutputLimit
  InvalidText
}

///|
async fn repository_read_process(reader : @process.ReadFromProcess) -> Bytes {
  let output = @buffer.Buffer()
  for ;; {
    match reader.read_some(max_len=8192) {
      None => break
      Some(bytes) => {
        guard bytes.length() <= 1048576 - output.length() else {
          raise RepositoryProcessFailure::OutputLimit
        }
        output.write_bytes(bytes)
      }
    }
  }
  output.to_bytes()
}

///|
async fn repository_git(args : Array[String]) -> RepositoryGitResult {
  guard acceptance_process_allowed("git", args) else {
    return { code: 128, stdout: "", }
  }
  @async.with_timeout(10000) <| () => {
    let (stdout, child_stdout) = @process.read_from_process()
    defer stdout.close()
    let (stderr, child_stderr) = @process.read_from_process()
    defer stderr.close()
    let (child_stdin, input) = @process.write_to_process()
    input.close()
    @async.with_task_group() <| group => {
      let process = group.spawn(() => {
        @process.run(
          "git",
          args,
          stdin=child_stdin,
          stdout=child_stdout,
          stderr=child_stderr,
          extra_env={
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "LC_ALL": "C",
          },
          cancel_handler=@process.hard_cancel(),
        )
      })
      let error_reader = group.spawn(() => repository_read_process(stderr))
      let bytes = repository_read_process(stdout)
      ignore(error_reader.wait())
      let code = process.wait()
      let stdout = @utf8.decode(bytes) catch { _ => raise InvalidText }
      { code, stdout, }
    }
  }
}
