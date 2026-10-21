///|
/// A deletion must resolve one exact name to a positive numeric asset ID.
/// Reject malformed or ambiguous metadata instead of guessing a write route.
fn business_release_asset_id(
  metadata : Json,
  name : String,
) -> Result[String, @github_cli.Output] {
  guard metadata is Object(fields) &&
    fields.get("assets") is Some(Array(assets)) else {
    return Err(
      @github_cli.failure(message="release response has no assets array"),
    )
  }
  let mut selected : String? = None
  for asset in assets {
    guard asset is Object(fields) &&
      fields.get("name") is Some(String(asset_name)) &&
      !asset_name.is_empty() &&
      fields.get("id") is Some(id) &&
      id is Number(_, ..) else {
      return Err(
        @github_cli.failure(message="release response has an invalid asset"),
      )
    }
    // Parsing the JSON number as an integer also rejects fractional IDs,
    // overflow, and route-like strings without truncating to an Int32.
    let identifier = @string.parse_int64(id.stringify()) catch {
      _ =>
        return Err(
          @github_cli.failure(message="release asset has an invalid id"),
        )
    }
    guard identifier > 0L else {
      return Err(@github_cli.failure(message="release asset has an invalid id"))
    }
    if asset_name == name {
      guard selected is None else {
        return Err(
          @github_cli.failure(
            message="release response has duplicate asset names",
          ),
        )
      }
      selected = Some(identifier.to_string())
    }
  }
  match selected {
    Some(identifier) => Ok(identifier)
    None => Err(@github_cli.failure(message="asset not found: " + name))
  }
}

///|
async fn execute_release_delete_asset(
  parsed : ParsedBusiness,
  request : BusinessRequest,
  metadata_response : @github.RawResponse,
  client : @github.Client,
  repository : @github_cli.RepositoryContext?,
) -> @github_cli.Output {
  if metadata_response.status() < 200 || metadata_response.status() >= 300 {
    return render_github_response(
      metadata_response.status(),
      metadata_response.headers(),
      metadata_response.body(),
    )
  }
  let metadata = match business_release_metadata(metadata_response) {
    Ok(value) => value
    Err(error) => return error
  }
  let name = match parsed.positionals.get(1) {
    Some(value) => value
    None => return @github_cli.failure(message="asset name is required")
  }
  let asset_id = match business_release_asset_id(metadata, name) {
    Ok(value) => value
    Err(error) => return error
  }
  let repo = match business_explicit_repository("release", parsed) {
    Some(value) =>
      match @github_cli.RepositoryContext::parse(value) {
        Ok(value) => value
        Err(_) =>
          return @github_cli.failure(
            message="expected the [HOST/]OWNER/REPO format",
          )
      }
    None =>
      match repository {
        Some(value) => value
        None => return @github_cli.failure(message="a repository is required")
      }
  }
  let response = match
    client.request(
      @github.Request::new(
        verb="DELETE",
        path=repo_api_path(repo) + "/releases/assets/" + asset_id,
        headers=request.headers,
      ),
      operation_id="release-delete-asset-" + asset_id,
      operation_name="release.delete-asset",
    ) {
    Ok(value) => value
    Err(error) =>
      match error.response() {
        Some(value) => value
        None => return @github_cli.failure(message=error.code())
      }
  }
  if response.status() >= 200 && response.status() < 300 {
    return @github_cli.success(stdout="")
  }
  render_github_response(response.status(), response.headers(), response.body())
}
