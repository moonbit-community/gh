///|
async test "extract validated archive publishes all nested files at once" {
  let directory = @fs.tmpdir(prefix="gh-archive-extract-")
  defer @fs.rmdir(directory, recursive=true)
  let source = directory + "/source.zip"
  let archive = @zip.Archive()
  archive.add("nested/a", b"\x00\xff", compression=Store)
  archive.add("b", b"text", compression=Deflate)
  @fs.write_file(source, @zip.write(archive))
  let files = @download.extract_zip_new(source, directory + "/output")
  assert_eq(files, ["nested/a", "b"])
  assert_eq(@fs.read_file(directory + "/output/nested/a").binary(), b"\x00\xff")
  assert_eq(@fs.read_file(directory + "/output/b").text(), "text")
  assert_eq(@fs.readdir(directory, sort=true), ["output", "source.zip"])
}

///|
async test "archive extraction never follows a pre-existing destination symlink" {
  let directory = @fs.tmpdir(prefix="gh-archive-boundary-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.mkdir(directory + "/outside")
  @fs.write_file(directory + "/outside/keep", b"original")
  let archive = @zip.Archive()
  archive.add("keep", b"replacement")
  @fs.write_file(directory + "/source.zip", @zip.write(archive))
  @fs.symlink(directory + "/output", target=directory + "/outside")
  let refused = try {
    ignore(
      @download.extract_zip_new(
        directory + "/source.zip",
        directory + "/output",
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(refused)
  assert_eq(@fs.read_file(directory + "/outside/keep").binary(), b"original")
  assert_eq(@fs.readdir(directory, sort=true), [
    "output", "outside", "source.zip",
  ])
}

///|
async test "unsafe archive is rejected before creating any destination or temporary tree" {
  let directory = @fs.tmpdir(prefix="gh-archive-unsafe-")
  defer @fs.rmdir(directory, recursive=true)
  let archive = @zip.Archive()
  archive.add("safe", b"first")
  archive.add("../escape", b"escape")
  @fs.write_file(directory + "/source.zip", @zip.write(archive))
  let refused = try {
    ignore(
      @download.extract_zip_new(
        directory + "/source.zip",
        directory + "/output",
      ),
    )
    false
  } catch {
    _ => true
  }
  assert_true(refused)
  assert_eq(@fs.readdir(directory), ["source.zip"])
}

///|
async test "archive merge replaces a regular file and preserves unrelated and empty directories" {
  let directory = @fs.tmpdir(prefix="gh-archive-merge-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.mkdir(directory + "/out")
  @fs.write_file(directory + "/out/keep", "keep")
  @fs.write_file(directory + "/out/replace", "old")
  let archive = @zip.Archive()
  archive.add("replace", b"new")
  archive.add("nested/value", b"\x00\xff")
  archive.add("empty/", b"")
  @fs.write_file(directory + "/source.zip", @zip.write(archive))
  ignore(@download.extract_zip(directory + "/source.zip", directory + "/out"))
  assert_eq(@fs.read_file(directory + "/out/keep").text(), "keep")
  assert_eq(@fs.read_file(directory + "/out/replace").text(), "new")
  assert_eq(
    @fs.read_file(directory + "/out/nested/value").binary(),
    b"\x00\xff",
  )
  assert_eq(@fs.kind(directory + "/out/empty"), @fs.Directory)
  let names = @fs.readdir(directory + "/out")
  assert_eq(names.length(), 4)
  assert_true(
    ["empty", "keep", "nested", "replace"].all(name => names.contains(name)),
  )
}

///|
async test "archive merge checks all existing symlink ancestors before replacing files" {
  let directory = @fs.tmpdir(prefix="gh-archive-merge-guard-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.mkdir(directory + "/out")
  @fs.mkdir(directory + "/other")
  @fs.write_file(directory + "/out/first", "original")
  @fs.write_file(directory + "/other/keep", "outside")
  @fs.symlink(directory + "/out/nested", target=directory + "/other")
  let archive = @zip.Archive()
  archive.add("first", b"replacement")
  archive.add("nested/keep", b"bad")
  @fs.write_file(directory + "/source.zip", @zip.write(archive))
  let refused = try {
    ignore(@download.extract_zip(directory + "/source.zip", directory + "/out"))
    false
  } catch {
    _ => true
  }
  assert_true(refused)
  assert_eq(@fs.read_file(directory + "/out/first").text(), "original")
  assert_eq(@fs.read_file(directory + "/other/keep").text(), "outside")
  assert_eq(@fs.readdir(directory + "/out", sort=true), ["first", "nested"])
}
