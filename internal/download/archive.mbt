///|
/// Validate and materialize only inside a fresh private directory. Publishing
/// the directory is one no-replace rename; a pre-existing destination or
/// symlink is never traversed or merged by this primitive.
pub async fn extract_zip_new(
  source : String,
  target : String,
  max_package_bytes~ : Int32 = 67108864,
  max_entry_bytes~ : Int32 = 134217728,
  max_total_bytes~ : Int32 = 268435456,
) -> Array[String] {
  guard max_package_bytes > 0 else { fail("invalid ZIP package limit") }
  let input = @fs.open(source, mode=ReadOnly)
  defer input.close()
  guard input.kind() == @fs.Regular &&
    input.size() <= max_package_bytes.to_int64() else {
    fail("ZIP source is not a bounded regular file")
  }
  let buffer = @buffer.Buffer()
  while input.read_some(max_len=65536) is Some(bytes) {
    guard bytes.length() <= max_package_bytes - buffer.length() else {
      fail("ZIP package exceeds its byte limit")
    }
    buffer.write_bytes(bytes)
  }
  let entries = @archive.decode_zip(
    buffer.to_bytes(),
    max_package_bytes~,
    max_entry_bytes~,
    max_total_bytes~,
    cancelled=@async.is_being_cancelled,
  )
  let (parent, name) = match target.rev_split_once("/") {
    Some((parent, name)) =>
      (if parent.is_empty() { "/" } else { parent.to_owned() }, name.to_owned())
    None => (".", target)
  }
  guard !name.is_empty() &&
    name != "." &&
    name != ".." &&
    !name.contains_char('\\') &&
    !name.contains_char(':') &&
    !name.contains_char('\u0000') else {
    fail("invalid archive destination")
  }
  let parent = @fs.realpath(parent)
  let destination = parent + "/" + name
  guard !@fs.exists(destination) else { fail("archive destination exists") }
  let stage = parent + "/.gh-extract-" + temporary_suffix()
  @fs.mkdir(stage, permission=0o700)
  let mut committed = false
  defer (if !committed { @fs.rmdir(stage, recursive=true) })
  for entry in entries {
    let components = entry.path().split("/").collect()
    let directory_count = components.length() -
      (if entry.directory() { 0 } else { 1 })
    let mut directory = stage
    for component in components[:directory_count] {
      directory += "/" + component.to_owned()
      if @fs.exists(directory) {
        guard @fs.kind(directory, follow_symlink=false) == @fs.Directory else {
          fail("archive directory is not a real directory")
        }
      } else {
        @fs.mkdir(directory, permission=0o700)
      }
    }
    if !entry.directory() {
      // CreateNew also detects filesystem-specific aliases (including Unicode
      // normalization on macOS) before any output directory is published.
      let file = @fs.open(
        stage + "/" + entry.path(),
        mode=WriteOnly,
        create_mode=CreateNew,
        permission=if entry.executable() { 0o700 } else { 0o600 },
      )
      defer file.close()
      file.write(entry.data().to_owned())
      file.sync()
    }
  }
  @fs.rename(stage, destination, replace=false)
  committed = true
  entries.filter(entry => !entry.directory()).map(entry => entry.path())
}

///|
/// Materialize and validate in a private staging tree, then publish regular
/// files by rename. Existing paths are checked before any file is replaced;
/// archive symlinks and existing symlink ancestors are never accepted.
/// Completed files may remain after an I/O failure, matching gh extraction;
/// the incomplete staging tree is always removed.
pub async fn extract_zip(
  source : String,
  target : String,
  max_package_bytes~ : Int32 = 67108864,
  max_entry_bytes~ : Int32 = 134217728,
  max_total_bytes~ : Int32 = 268435456,
) -> Array[String] {
  // Staging in the destination filesystem also makes each final rename atomic.
  // Validate the package before creating user-visible destination directories.
  let workspace = @fs.tmpdir(prefix="gh-artifact-validate-")
  defer @fs.rmdir(workspace, recursive=true)
  let files = extract_zip_new(
    source,
    workspace + "/validated",
    max_package_bytes~,
    max_entry_bytes~,
    max_total_bytes~,
  )
  let directories : Array[String] = []
  let validated = workspace + "/validated"
  @fs.walk(
    validated,
    (path, _) => {
      if path.strip_prefix(validated + "/") is Some(relative) {
        directories.push(relative.to_owned())
      }
    },
    max_concurrency=1,
  )
  directories.sort()
  if !@fs.exists(target) {
    @fs.mkdir(target, recursive=true, permission=0o755)
  }
  guard @fs.kind(target, follow_symlink=false) == @fs.Directory else {
    fail("archive destination is not a real directory")
  }
  let root = @fs.realpath(target)
  let stage = root + "/.gh-extract-" + temporary_suffix()
  @fs.mkdir(stage, permission=0o700)
  defer @fs.rmdir(stage, recursive=true)
  // Check every directory and final name before replacing any existing file.
  // Filesystem-specific alias collisions were checked in the validated tree.
  for
    (file, is_directory) in directories.map(path => (path, true)) +
    files.map(path => (path, false)) {
    let components = file.split("/").to_array()
    let mut path = root
    for i, component in components {
      path += "/" + component.to_owned()
      let kind = try @fs.kind(path, follow_symlink=false) catch {
        _ => None
      } noraise {
        kind => Some(kind)
      }
      if kind is Some(kind) {
        guard kind ==
          (if !is_directory && i + 1 == components.length() {
            @fs.Regular
          } else {
            @fs.Directory
          }) else {
          fail("archive destination contains a symlink or conflicting path")
        }
      }
    }
  }
  for directory in directories {
    let path = root + "/" + directory
    if !@fs.exists(path) {
      @fs.mkdir(path, permission=0o755)
    }
    guard @fs.kind(path, follow_symlink=false) == @fs.Directory else {
      fail("archive destination directory changed")
    }
  }
  for file in files {
    let components = file.split("/").to_array()
    let mut parent = root
    for component in components[:components.length() - 1] {
      parent += "/" + component.to_owned()
      if !@fs.exists(parent) {
        @fs.mkdir(parent, permission=0o755)
      }
      guard @fs.kind(parent, follow_symlink=false) == @fs.Directory else {
        fail("archive destination directory changed")
      }
    }
    let staged = stage + "/" + temporary_suffix()
    let input = @fs.open(workspace + "/validated/" + file, mode=ReadOnly)
    defer input.close()
    let output = @fs.open(
      staged,
      mode=WriteOnly,
      create_mode=CreateNew,
      permission=if @fs.can_execute(workspace + "/validated/" + file) {
        0o755
      } else {
        0o644
      },
    )
    defer output.close()
    while input.read_some(max_len=65536) is Some(bytes) {
      output.write(bytes)
    }
    output.sync()
    output.close()
    // Do not traverse a final symlink, including a dangling one.
    let destination = root + "/" + file
    let kind = try @fs.kind(destination, follow_symlink=false) catch {
      _ => None
    } noraise {
      kind => Some(kind)
    }
    guard kind is None || kind == Some(@fs.Regular) else {
      fail("archive destination file changed")
    }
    @fs.rename(staged, destination, replace=true)
  }
  files
}
