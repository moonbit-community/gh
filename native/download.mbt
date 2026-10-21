///|
/// Receive a response into a temporary sibling file and atomically publish it
/// after success. HTTP errors leave the destination unchanged. Cancellation,
/// framing failures and callback errors remove the incomplete temporary file.
pub async fn download_to_file(
  transport : @gh.RawTransport,
  request : @gh.RawRequest,
  target : String,
  replace~ : Bool = false,
) -> @gh.RawDownloadResult {
  @download.to_file(target, sink => transport.receive(request, sink), replace~)
}
