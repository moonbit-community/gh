///|
pub struct Artifact {
  id : String
  name : String
  expired : Bool
  download_path : String
}

///|
pub fn Artifact::id(self : Artifact) -> String {
  self.id
}

///|
pub fn Artifact::name(self : Artifact) -> String {
  self.name
}

///|
pub fn Artifact::expired(self : Artifact) -> Bool {
  self.expired
}

///|
pub fn Artifact::download_path(self : Artifact) -> String {
  self.download_path
}

///|
fn valid_repository(repository : String) -> Bool {
  let parts = repository.split("/").to_array()
  parts.length() == 2 &&
  parts.all(part => {
    !part.is_empty() &&
    part != "." &&
    part != ".." &&
    part
    .iter()
    .all(ch => ch is ('a'..<='z' | 'A'..<='Z' | '0'..<='9' | '-' | '_' | '.'))
  })
}

///|
fn numeric_id(value : String) -> Bool {
  !value.is_empty() && value.iter().all(ch => ch is ('0'..<='9'))
}

///|
/// Retain ordering from the API. Selection and same-name de-duplication are
/// CLI policy; this operation returns every page, including expired entries.
/// Every supplied download URL must describe this artifact in this repo.
pub async fn list_artifacts(
  client : @github.Client,
  repository : String,
  run_id? : String,
  max_pages~ : Int32 = 1000,
) -> Result[Array[Artifact], @github.GitHubError] {
  guard valid_repository(repository) && max_pages > 0 else {
    return Err(
      @github.GitHubError::invalid_request(
        "invalid artifacts repository or page limit",
      ),
    )
  }
  if run_id is Some(id) && !numeric_id(id) {
    return Err(@github.GitHubError::invalid_request("invalid workflow run ID"))
  }
  let root = "/repos/" + repository + "/actions"
  let collection = match run_id {
    Some(id) => root + "/runs/" + id + "/artifacts"
    None => root + "/artifacts"
  }
  let base = client.config.base_url()
  let mut path = collection + "?per_page=100"
  let visited : Map[String, Unit] = Map([])
  let identities : Map[String, Unit] = Map([])
  let output : Array[Artifact] = []
  for page in 0..<max_pages {
    guard !visited.contains(path) else {
      return Err(
        @github.GitHubError::decode("repeated artifacts pagination URL"),
      )
    }
    visited[path] = ()
    let response = match
      client.request(
        @github.Request::new(verb="GET", path~),
        operation_id="actions-artifacts",
        operation_name="actions.artifacts.list",
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let value = @json.parse(@utf8.decode(response.body())) catch {
      _ => return Err(@github.GitHubError::decode("invalid artifacts response"))
    }
    guard value is { "artifacts": Array(items), .. } else {
      return Err(@github.GitHubError::decode("missing artifacts collection"))
    }
    for item in items {
      guard item
        is {
          "id": Number(id, ..),
          "name": String(name),
          "expired": expired,
          "archive_download_url": String(url),
          ..
        } &&
        id > 0 &&
        id < 9007199254740992.0 &&
        id == id.to_int64().to_double() &&
        expired is (True | False) else {
        return Err(@github.GitHubError::decode("invalid artifact metadata"))
      }
      let id = id.to_int64().to_string()
      let download_path = root + "/artifacts/" + id + "/zip"
      guard url == base + download_path else {
        return Err(
          @github.GitHubError::decode(
            "artifact download URL does not match its repository and ID",
          ),
        )
      }
      guard !identities.contains(id) else {
        return Err(
          @github.GitHubError::decode("repeated artifact ID across pages"),
        )
      }
      identities[id] = ()
      output.push({ id, name, expired: expired is True, download_path, })
    }
    match response.next_url(current_url=base + path) {
      Err(error) => return Err(error)
      Ok(None) => return Ok(output)
      Ok(Some(url)) => {
        guard url.strip_prefix(base + collection + "?") is Some(query) &&
          !query.is_empty() else {
          return Err(
            @github.GitHubError::decode(
              "artifacts pagination left its collection",
            ),
          )
        }
        if page + 1 == max_pages {
          return Err(
            @github.GitHubError::decode("artifacts pagination limit reached"),
          )
        }
        path = collection + "?" + query.to_owned()
      }
    }
  }
  Err(@github.GitHubError::decode("artifacts pagination did not terminate"))
}
