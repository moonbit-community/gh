///|
fn cache_query_value(value : String) -> String {
  @percent.encode(value).replace_all(old="%20", new="+")
}

///|
/// Fetch all IDs before a bulk delete. Pagination must stay in this repository;
/// duplicate IDs and cycles fail before any deletion is attempted.
pub async fn workflow_cache_ids(
  client : @github.Client,
  repository : String,
  ref_name~ : String = "",
) -> Result[Array[String], @github.GitHubError] {
  guard valid_repository(repository) else {
    return Err(@github.GitHubError::invalid_request("invalid cache repository"))
  }
  let collection = "/repos/" + repository + "/actions/caches"
  let mut path = collection +
    "?per_page=100" +
    (if ref_name.is_empty() {
      ""
    } else {
      "&ref=" + cache_query_value(ref_name)
    })
  let base = client.config.base_url()
  let visited : Map[String, Unit] = Map([])
  let ids : Array[String] = []
  for _ in 0..<1000 {
    guard !visited.contains(path) else {
      return Err(@github.GitHubError::decode("repeated cache pagination URL"))
    }
    visited[path] = ()
    let (value, response) = match
      request_json(
        client,
        path,
        operation_id="actions-caches",
        operation_name="actions.caches.list",
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    guard value is { "actions_caches": Array(items), .. } else {
      return Err(@github.GitHubError::decode("missing caches collection"))
    }
    for item in items {
      guard id(item, "id") is Some(id) && !ids.contains(id) else {
        return Err(@github.GitHubError::decode("invalid or repeated cache ID"))
      }
      ids.push(id)
    }
    match response.next_url(current_url=base + path) {
      Err(error) => return Err(error)
      Ok(None) => return Ok(ids)
      Ok(Some(next)) => {
        guard next.strip_prefix(base + collection + "?") is Some(query) &&
          !query.is_empty() else {
          return Err(
            @github.GitHubError::decode("cache pagination left its collection"),
          )
        }
        path = collection + "?" + query.to_owned()
      }
    }
  }
  Err(@github.GitHubError::decode("cache pagination limit reached"))
}

///|
pub async fn delete_workflow_cache(
  client : @github.Client,
  repository : String,
  identifier : String,
  by_id~ : Bool,
  ref_name~ : String = "",
) -> Result[Int32, @github.GitHubError] {
  guard valid_repository(repository) else {
    return Err(@github.GitHubError::invalid_request("invalid cache repository"))
  }
  let collection = "/repos/" + repository + "/actions/caches"
  let path = if by_id {
    let digits = identifier.strip_prefix("-").unwrap_or(identifier[:])
    guard !digits.is_empty() &&
      digits.iter().all(ch => ch is ('0'..<='9')) &&
      ref_name.is_empty() else {
      return Err(@github.GitHubError::invalid_request("invalid cache ID"))
    }
    collection + "/" + identifier
  } else {
    collection +
    "?key=" +
    cache_query_value(identifier) +
    (if ref_name.is_empty() {
      ""
    } else {
      "&ref=" + cache_query_value(ref_name)
    })
  }
  let response = match
    client.request(
      @github.Request::new(verb="DELETE", path~),
      operation_id="actions-cache-delete",
      operation_name="cache.delete",
    ) {
    Ok(response) => response
    Err(error) => return Err(error)
  }
  if by_id {
    return Ok(1)
  }
  let value = @json.parse(@utf8.decode(response.body())) catch {
    _ =>
      return Err(@github.GitHubError::decode("invalid cache deletion response"))
  }
  guard value is { "total_count": Number(count, ..), .. } &&
    count >= 0 &&
    count <= 2147483647.0 &&
    count == count.to_int().to_double() else {
    return Err(@github.GitHubError::decode("invalid deleted cache count"))
  }
  Ok(count.to_int())
}
