///|
/// Stream a release asset without applying the ordinary API buffering cap.
/// The same explicit redirect allowlist and permanent credential removal used
/// by download_release_asset apply here. The sink receives only final 2xx
/// responses; redirects and HTTP failures never become file contents.
pub async fn Client::download_release_asset_into(
  self : Client,
  path : String,
  sink : @gh.RawResponseSink,
) -> Result[@gh.RawDownloadResult, GitHubError] {
  self.download_into(path, sink, actions=false)
}

///|
/// Download a run log, job log, or artifact ZIP from an origin-relative API
/// path. Redirects may only reach documented Actions storage, with API
/// credentials permanently removed at the first origin change.
pub async fn Client::download_actions_archive_into(
  self : Client,
  path : String,
  sink : @gh.RawResponseSink,
) -> Result[@gh.RawDownloadResult, GitHubError] {
  self.download_into(path, sink, actions=true)
}

///|
/// Source archives use the same bounded redirect handling, with GitHub's
/// credential-free Codeload origin and its canonical tagged archive paths.
pub async fn Client::download_release_archive_into(
  self : Client,
  path : String,
  sink : @gh.RawResponseSink,
) -> Result[@gh.RawDownloadResult, GitHubError] {
  self.download_into(path, sink, actions=false, archive=true)
}

///|
async fn Client::download_into(
  self : Client,
  path : String,
  sink : @gh.RawResponseSink,
  actions~ : Bool,
  archive~ : Bool = false,
) -> Result[@gh.RawDownloadResult, GitHubError] {
  let operation = if actions { "actions.download" } else { "release.download" }
  let mut downloaded : @gh.RawDownloadResult? = None
  let result = self.download_with(path, actions~, archive~, request => {
    let started = (self.clock)()
    let mut observed : @gh.RawResponseHead? = None
    let outcome = self.transport.receive(
      request_copy(request),
      @gh.RawResponseSink::new(
        headers=head => {
          observed = Some(head)
          if head.status() >= 200 && head.status() < 300 {
            sink.headers(head)
          } else {
            false
          }
        },
        chunk=bytes => sink.chunk(bytes),
      ),
    ) catch {
      error if @async.is_being_cancelled() => {
        self.record_attempt(
          request,
          operation_id=operation,
          operation_name=operation,
          attempt=1,
          started~,
          error_code="cancelled",
          status?=observed.map(head => head.status()),
        )
        raise error
      }
      _ => Err(TransportError::Failed)
    }
    let result = match outcome {
      Err(TransportError::Cancelled) => Err(GitHubError::Cancelled)
      Err(_) => Err(GitHubError::Transport(message="download did not complete"))
      Ok(value) => {
        let response = RawResponse::new(
          status=value.head().status(),
          headers=value.head().headers(),
          reason_phrase?=value.head().reason_phrase(),
        )
        if response.status() >= 200 && response.status() < 300 {
          downloaded = Some(value)
          Ok(response)
        } else {
          Err(http_error(response))
        }
      }
    }
    self.record_attempt(
      request,
      operation_id=operation,
      operation_name=operation,
      attempt=1,
      started~,
      status?=observed.map(head => head.status()),
      request_id?=match observed {
        Some(head) => head.header("x-github-request-id")
        None => None
      },
      error_code?=match result {
        Err(error) => Some(error.code())
        _ => None
      },
    )
    result
  })
  match result {
    Err(error) => Err(error)
    Ok(_) =>
      match downloaded {
        Some(value) => Ok(value)
        None =>
          Err(GitHubError::Transport(message="download has no final response"))
      }
  }
}
