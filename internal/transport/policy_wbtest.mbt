///|
async test "raw invalid input fails before dialing or consuming stream" {
  let transport = native_raw_transport(
    base_url="https://must-not-contact.invalid",
  )
  let requests = [
    @gh.RawRequest::new(verb="GET\r\nInjected", path="/safe"),
    @gh.RawRequest::new(verb="", path="/safe"),
    @gh.RawRequest::new(verb="GET", path="//other.invalid/path"),
    @gh.RawRequest::new(verb="GET", path="https://other.invalid/path"),
    @gh.RawRequest::new(verb="GET", path="/path\r\nInjected: true"),
    @gh.RawRequest::new(verb="GET", path="/%2e%2e/private"),
    @gh.RawRequest::new(verb="GET", path="/safe%0d%0aInjected"),
    @gh.RawRequest::new(verb="GET", path="/safe%5cprivate"),
    @gh.RawRequest::new(verb="GET", path="/safe%2"),
    @gh.RawRequest::new(verb="GET", path="/safe", headers=[
      ("Bad Name", "value"),
    ]),
    @gh.RawRequest::new(verb="GET", path="/safe", headers=[
      ("X-Test", "value\r\nInjected: true"),
    ]),
    @gh.RawRequest::new(verb="GET", path="/safe", headers=[
      ("Host", "other.invalid"),
    ]),
    @gh.RawRequest::new(verb="GET", path="/safe", headers=[
      ("Content-Length", "4"),
    ]),
  ]
  for request in requests {
    let rejected = try {
      ignore(transport.send(request))
      false
    } catch {
      NativeTransportFailure::InvalidRequest => true
      _ => false
    }
    assert_true(rejected)
  }
  let mut consumed = false
  let stream = @gh.RawBodyStream::new(length=-1, next=() => {
    consumed = true
    None
  })
  let rejected = try {
    ignore(
      transport.send(
        @gh.RawRequest::from_stream(verb="POST", path="/safe", stream~),
      ),
    )
    false
  } catch {
    NativeTransportFailure::InvalidRequest => true
    _ => false
  }
  assert_true(rejected)
  assert_false(consumed)
}
