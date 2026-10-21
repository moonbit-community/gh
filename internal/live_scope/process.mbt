///|
/// Until a checkout has a verified remote and a dedicated process permit,
/// acceptance permits only these literal Git metadata reads. In particular
/// aliases, -c, global config writes, clone, fetch, push and shells cannot run.
pub fn Policy::allows_process(
  _self : Policy,
  program : String,
  args : Array[String],
) -> Bool {
  guard program is ("git" | "/usr/bin/git") else { return false }
  match args[:] {
    ["rev-parse", "--show-toplevel"]
    | ["rev-parse", "--show-prefix"]
    | ["rev-parse", "--is-inside-work-tree"]
    | ["symbolic-ref", "--quiet", "--short", "HEAD"]
    | ["branch", "--show-current"]
    | ["remote", "-v"] => true
    ["config", "--get", key] =>
      key
      is ("remote.origin.url"
      | "remote.origin.pushurl"
      | "gh-resolved"
      | "branch.main.remote")
    ["config", "--get-regexp", "remote\\..*\\.url"] => true
    ["remote", "get-url", name] | ["remote", "get-url", "--push", name] =>
      name is ("origin" | "upstream" | "github")
    _ => false
  }
}
