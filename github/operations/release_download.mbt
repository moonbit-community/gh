///|
pub struct ReleaseDownloadAsset {
  name : String
  path : String
}

///|
pub struct ReleaseDownloadMetadata {
  name : String
  tag : String
  draft : Bool
  assets : Array[ReleaseDownloadAsset]
  zip_url : String
  tar_url : String
}

///|
fn release_string(value : Json, key : String) -> String {
  match value {
    Object(fields) =>
      match fields.get(key) {
        Some(String(value)) => value
        _ => ""
      }
    _ => ""
  }
}

///|
pub async fn release_download_metadata(
  client : @github.Client,
  repository : String,
  tag : String?,
) -> Result[ReleaseDownloadMetadata, @github.GitHubError] {
  guard valid_repository(repository) else {
    return Err(
      @github.GitHubError::invalid_request("invalid release repository"),
    )
  }
  let path = "/repos/" +
    repository +
    "/releases/" +
    (match tag {
      Some(tag) => "tags/" + @percent.encode(tag)
      None => "latest"
    })
  let response = match
    client.request(
      @github.Request::new(verb="GET", path~),
      operation_id="release-download-metadata",
      operation_name="release.download",
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let value = @json.parse(@utf8.decode(response.body())) catch {
    _ => return Err(@github.GitHubError::decode("invalid release metadata"))
  }
  guard value is { "assets": Array(items), .. } else {
    return Err(@github.GitHubError::decode("missing release assets"))
  }
  let assets : Array[ReleaseDownloadAsset] = []
  let seen : Map[String, Unit] = Map([])
  for item in items {
    guard item is { "id": id, "name": String(name), .. } else {
      return Err(@github.GitHubError::decode("invalid release asset"))
    }
    let id = match id {
      Number(_, ..) => id.stringify()
      String(value) => value
      _ => ""
    }
    guard !id.is_empty() &&
      id.iter().all(ch => ch is ('0'..<='9')) &&
      !name.is_empty() &&
      !seen.contains(name) else {
      return Err(
        @github.GitHubError::decode("invalid or duplicate release asset"),
      )
    }
    seen[name] = ()
    let path = "/repos/" + repository + "/releases/assets/" + id
    let url = release_string(item, "url")
    guard url.is_empty() || url == client.config.base_url() + path else {
      return Err(
        @github.GitHubError::decode("release asset left its repository"),
      )
    }
    assets.push({ name, path, })
  }
  Ok({
    name: release_string(value, "name"),
    tag: release_string(value, "tag_name"),
    draft: value is { "draft": True, .. },
    assets,
    zip_url: release_string(value, "zipball_url"),
    tar_url: release_string(value, "tarball_url"),
  })
}
