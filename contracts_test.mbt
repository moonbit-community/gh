///|
test "provider-neutral request has an explicit method and path" {
  let request = @gh.Request::new(verb=@gh.get_method(), path="/api/v1/meta")
  assert_true(request.verb is @gh.HttpMethod::Get)
  assert_eq(request.path, "/api/v1/meta")
  assert_true(request.body is None)
}
