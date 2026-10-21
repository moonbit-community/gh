///|
pub struct ReleaseAttestation {
  bundle : Json?
  bundle_url : String
}

///|
pub async fn release_ref_digest(
  client : @github.Client,
  repository : String,
  tag : String,
) -> Result[String, @github.GitHubError] {
  guard valid_repository(repository) && !tag.is_empty() else {
    return Err(
      @github.GitHubError::invalid_request("invalid release repository or tag"),
    )
  }
  let path = "/repos/" +
    repository +
    "/git/ref/" +
    @percent.encode("tags/" + tag)
  let response = match
    client.request(
      @github.Request::new(verb="GET", path~),
      operation_id="release-ref",
      operation_name="release.ref",
    ) {
    Ok(response) => response
    Err(error) => return Err(error)
  }
  let metadata = @json.parse(@utf8.decode(response.body())) catch {
    _ => return Err(@github.GitHubError::decode("invalid release ref JSON"))
  }
  guard metadata is { "object": { "sha": String(sha), .. }, .. } &&
    (sha.length() == 40 || sha.length() == 64) &&
    sha.iter().all(c => c is ('0'..<='9' | 'a'..<='f' | 'A'..<='F')) else {
    return Err(@github.GitHubError::decode("invalid release ref SHA"))
  }
  Ok((if sha.length() == 64 { "sha256:" } else { "sha1:" }) + sha)
}

///|
pub async fn list_release_attestations(
  client : @github.Client,
  repository : String,
  ref_digest : String,
) -> Result[Array[ReleaseAttestation], @github.GitHubError] {
  guard valid_repository(repository) &&
    !ref_digest.is_empty() &&
    ref_digest
    .iter()
    .all(c => c is ('0'..<='9' | 'a'..<='z' | 'A'..<='Z' | ':')) else {
    return Err(
      @github.GitHubError::invalid_request("invalid release attestation query"),
    )
  }
  let collection = "/repos/" + repository + "/attestations/" + ref_digest
  let base = client.config.base_url()
  let mut path = collection + "?per_page=100&predicate_type=release"
  let visited : Map[String, Unit] = Map([])
  let output : Array[ReleaseAttestation] = []
  for _ in 0..<1000 {
    guard !visited.contains(path) else {
      return Err(
        @github.GitHubError::decode("repeated attestation pagination URL"),
      )
    }
    visited[path] = ()
    let response = match
      client.request(
        @github.Request::new(verb="GET", path~),
        operation_id="release-attestations",
        operation_name="release.attestations",
        retry_policy=@github.RetryPolicy::server_errors(max_attempts=4),
      ) {
      Ok(response) => response
      Err(error) => return Err(error)
    }
    let value = @bounded_json.parse(@utf8.decode(response.body())) catch {
      _ =>
        return Err(
          @github.GitHubError::decode("invalid release attestations JSON"),
        )
    }
    guard value is { "attestations": Array(items), .. } else {
      return Err(
        @github.GitHubError::decode("missing release attestation collection"),
      )
    }
    for item in items {
      guard item is Object(fields) else {
        return Err(@github.GitHubError::decode("invalid release attestation"))
      }
      if fields.get("initiator") != Some(Json("github")) {
        continue
      }
      let bundle = match fields.get("bundle") {
        Some(Null) => None
        value => value
      }
      let bundle_url = match fields.get("bundle_url") {
        Some(String(url)) => url
        _ => ""
      }
      guard bundle is Some(_) || !bundle_url.is_empty() else {
        return Err(
          @github.GitHubError::decode("attestation has no bundle or bundle URL"),
        )
      }
      output.push({ bundle, bundle_url, })
      if output.length() == 100 {
        return Ok(output)
      }
    }
    match response.next_url(current_url=base + path) {
      Err(error) => return Err(error)
      Ok(None) => return Ok(output)
      Ok(Some(url)) => {
        guard url.strip_prefix(base + collection + "?") is Some(query) else {
          return Err(
            @github.GitHubError::decode(
              "attestation pagination left its collection",
            ),
          )
        }
        path = collection + "?" + query.to_owned()
      }
    }
  }
  Err(@github.GitHubError::decode("attestation pagination limit reached"))
}

///|
pub async fn release_trust_domain(
  client : @github.Client,
) -> Result[String, @github.GitHubError] {
  let response = match
    client.request(
      @github.Request::new(verb="GET", path="/meta"),
      operation_id="release-trust-domain",
      operation_name="release.trust-domain",
      retry_policy=@github.RetryPolicy::server_errors(max_attempts=4),
    ) {
    Ok(response) => response
    Err(error) => return Err(error)
  }
  let metadata = @bounded_json.parse(@utf8.decode(response.body())) catch {
    _ =>
      return Err(
        @github.GitHubError::decode("invalid release trust domain JSON"),
      )
  }
  let mut value = metadata
  for key in ["domains", "artifact_attestations", "trust_domain"] {
    match value {
      Null => return Ok("")
      Object(fields) =>
        match fields.get(key) {
          None => return Ok("")
          Some(field) => value = field
        }
      _ =>
        return Err(
          @github.GitHubError::decode("invalid release trust domain metadata"),
        )
    }
  }
  match value {
    Null => Ok("")
    String(domain) => Ok(domain)
    _ => Err(@github.GitHubError::decode("invalid release trust domain"))
  }
}
