///|
test "MoonHub client uses the versioned API prefix" {
  let config = @moonhub.ClientConfig::new(base_url="https://moonhub.example")
  assert_eq(
    config.endpoint(path="/meta"),
    "https://moonhub.example/api/v1/meta",
  )
}
