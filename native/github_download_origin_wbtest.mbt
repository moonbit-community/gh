///|
test "Native download selection recognizes the source archive CDN without broadening host matching" {
  assert_eq(
    github_download_origin("https://codeload.github.com/cli/cli/zip/v2.102.0"),
    Some("https://codeload.github.com"),
  )
  assert_eq(
    github_download_origin(
      "https://release-assets.githubusercontent.com/asset?sig=synthetic",
    ),
    Some("https://release-assets.githubusercontent.com"),
  )
  assert_eq(
    github_download_origin("https://fixture.blob.core.windows.net/artifact"),
    Some("https://fixture.blob.core.windows.net"),
  )
  for
    url in [
      "http://codeload.github.com/source", "https://codeload.github.com.evil.example/source",
      "https://codeload.github.com@evil.example/source", "https://evil.example/codeload.github.com/source",
      "https://codeload.github.com:444/source", "https://codeload.github.com\\evil/source",
    ] {
    assert_eq(github_download_origin(url), None)
  }
}
