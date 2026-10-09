///|
/// Append one sanitized completion record to an explicitly selected JSONL file.
/// The caller owns a private directory; parent creation and retention policy
/// belong to the CLI. Existing symlinks and nonregular files are refused. The
/// upstream filesystem API has no descriptor-based chmod/no-follow open, so
/// this is not a defense against concurrent hostile directory modifications.
///
/// On POSIX, files are created with owner-only permissions and existing files
/// tightened before writing. Windows inherits the caller's private directory
/// ACL; the upstream adapter cannot inspect or change ACLs. POSIX cooperating
/// writers serialize appends with an advisory lock. The pinned upstream Windows
/// adapter currently returns ERROR_ACCESS_DENIED for its simulated advisory
/// lock, so Windows requires a private single-writer trace file until a native
/// Windows lock adapter is available.
/// A crash can leave the attempt unrecorded or the final line incomplete.
pub async fn append(
  path : String,
  record : @gh.TraceRecord,
  secrets? : Array[String] = [],
) -> Unit {
  if path.is_empty() || path == "-" {
    fail("Trace output requires an explicit regular file")
  }
  let line = record.to_json_line(secrets~)
  try @fs.kind(path, follow_symlink=false) catch {
    @os_error.OSError(_) as error if error.is_ENOENT() => ()
    error => raise error
  } noraise {
    Regular => ()
    _ => fail("Trace output must be a regular file")
  }
  let file = @fs.open(
    path,
    mode=WriteOnly,
    create_mode=OpenOrCreate,
    append=true,
    permission=0o600,
    sync=Data,
  )
  defer file.close()
  if file.kind() != @fs.Regular {
    fail("Trace output must be a regular file")
  }
  restrict_posix_permissions(path)
  lock_exclusive(file)
  defer unlock_trace(file)
  file.write(line)
}

///|
#cfg(not(platform="windows"))
async fn lock_exclusive(file : @fs.File) -> Unit {
  file.lock(Exclusive)
}

///|
#cfg(platform="windows")
fn lock_exclusive(_file : @fs.File) -> Unit {

}

///|
#cfg(not(platform="windows"))
fn unlock_trace(file : @fs.File) -> Unit {
  file.unlock()
}

///|
#cfg(platform="windows")
fn unlock_trace(_file : @fs.File) -> Unit {

}

///|
#cfg(not(platform="windows"))
async fn restrict_posix_permissions(path : String) -> Unit {
  @fs.chmod(path, 0o600)
}

///|
#cfg(platform="windows")
fn restrict_posix_permissions(_path : String) -> Unit {
  // Windows permissions belong to the parent directory's ACL. Calling the
  // unsupported chmod adapter would make every successful trace append fail.
  ()
}
