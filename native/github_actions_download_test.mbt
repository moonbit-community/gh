///|
async test "run download paginates filters expired deduplicates and extracts exact binary files" {
  let directory = @fs.tmpdir(prefix="gh-actions-fixture-")
  defer @fs.rmdir(directory, recursive=true)
  let seen : Array[String] = []
  let archive = @zip.Archive()
  archive.add("nested/binary", b"\x00\xff\x80\n", compression=Deflate)
  let zip = @zip.write(archive)
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.com"),
      transport=@github.Transport::new(send=request => {
        seen.push(request.path())
        match request.path() {
          "/repos/acme/widgets/actions/runs/7/artifacts?per_page=100" => {
            let body : Json = {
              "artifacts": [
                {
                  "id": 1,
                  "name": "old",
                  "expired": true,
                  "archive_download_url": "https://api.github.com/repos/acme/widgets/actions/artifacts/1/zip",
                },
                {
                  "id": 2,
                  "name": "linux",
                  "expired": false,
                  "archive_download_url": "https://api.github.com/repos/acme/widgets/actions/artifacts/2/zip",
                },
              ],
            }
            Ok(
              @github.RawResponse::new(
                status=200,
                body=@utf8.encode(body.stringify()),
                headers=[("Link", "<?page=2>; rel=\"next\"")],
              ),
            )
          }
          "/repos/acme/widgets/actions/runs/7/artifacts?page=2" => {
            let body : Json = {
              "artifacts": [
                {
                  "id": 3,
                  "name": "linux",
                  "expired": false,
                  "archive_download_url": "https://api.github.com/repos/acme/widgets/actions/artifacts/3/zip",
                },
                {
                  "id": 4,
                  "name": "mac",
                  "expired": false,
                  "archive_download_url": "https://api.github.com/repos/acme/widgets/actions/artifacts/4/zip",
                },
              ],
            }
            Ok(
              @github.RawResponse::new(
                status=200,
                body=@utf8.encode(body.stringify()),
              ),
            )
          }
          "/repos/acme/widgets/actions/artifacts/2/zip"
          | "/repos/acme/widgets/actions/artifacts/4/zip" =>
            Ok(@github.RawResponse::new(status=200, body=zip))
          path => fail("unexpected request: " + path)
        }
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  guard @github_cli.RepositoryContext::parse("acme/widgets") is Ok(repository) else {
    fail("repo")
  }
  guard @github_cli.parse([
      "run", "download", "7", "-R", "acme/widgets", "-D", directory, "-n", "linux",
      "-p", "m??",
    ])
    is @github_cli.Business(options) else {
    fail("args")
  }
  let result = @native.execute_github_business(
    options,
    client~,
    repository~,
    base_url="https://api.github.com",
  )
  assert_eq(result.stderr(), "")
  assert_eq(result.exit_code(), 0)
  assert_eq(result.stdout(), "")
  assert_eq(seen.length(), 4)
  let names = @fs.readdir(directory)
  assert_eq(names.length(), 2)
  assert_true(names.contains("linux") && names.contains("mac"))
  for name in ["linux", "mac"] {
    assert_eq(
      @fs.read_file(directory + "/" + name + "/nested/binary").binary(),
      b"\x00\xff\x80\n",
    )
  }
}

///|
async test "run download one explicit name merges directly without deleting unrelated files" {
  let directory = @fs.tmpdir(prefix="gh-actions-one-")
  defer @fs.rmdir(directory, recursive=true)
  @fs.write_file(directory + "/keep", "keep")
  @fs.write_file(directory + "/replace", "before")
  let archive = @zip.Archive()
  archive.add("replace", b"after")
  let body : Json = {
    "artifacts": [
      {
        "id": 1,
        "name": "single",
        "expired": false,
        "archive_download_url": "https://api.github.com/repos/acme/widgets/actions/artifacts/1/zip",
      },
    ],
  }
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="https://api.github.com"),
      transport=@github.Transport::new(send=request => {
        Ok(
          @github.RawResponse::new(
            status=200,
            body=if request.path().has_suffix("/zip") {
              @zip.write(archive)
            } else {
              @utf8.encode(body.stringify())
            },
          ),
        )
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  guard @github_cli.RepositoryContext::parse("acme/widgets") is Ok(repository) else {
    fail("repo")
  }
  guard @github_cli.parse([
      "run", "download", "-R", "acme/widgets", "-D", directory, "-nsingle",
    ])
    is @github_cli.Business(options) else {
    fail("args")
  }
  let result = @native.execute_github_business(
    options,
    client~,
    repository~,
    base_url="https://api.github.com",
  )
  assert_eq(result.stderr(), "")
  assert_eq(result.exit_code(), 0)
  assert_eq(@fs.readdir(directory, sort=true), ["keep", "replace"])
  assert_eq(@fs.read_file(directory + "/replace").text(), "after")
  assert_eq(@fs.read_file(directory + "/keep").text(), "keep")
}
