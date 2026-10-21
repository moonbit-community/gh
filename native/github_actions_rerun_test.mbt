///|
/// Run the committed oracle cases against the SDK seam on every Native CI
/// platform. The separate subprocess differential checks the actual executable.
async fn check_actions_mutation_oracle(encoded : String) -> Unit {
  let case = @json.parse(encoded)
  guard case
    is {
      "args": Array(args),
      "routes": Object(routes),
      "stdout": String(stdout),
      "stderr": String(stderr),
      "exit_code": Number(exit_code, ..),
      "request_messages": Array(expected),
      ..
    } else {
    fail("invalid Actions oracle case")
  }
  let requests : Array[Json] = []
  guard @github.Client::new(
      config=@github.ClientConfig::new(base_url="http://api.github.localhost"),
      transport=@github.Transport::new(send=request => {
        let body = request.body().map_or("", bytes => @utf8.decode(bytes))
        requests.push({
          "method": request.verb(),
          "path": request.path(),
          "raw_body": body,
          "json_body": if body.is_empty() {
            Json::null()
          } else {
            @json.parse(body)
          },
        })
        guard routes.get(request.path()) is Some(route) else {
          fail("unexpected Actions request")
        }
        let route = match route {
          { "sequence": Array(steps), .. } if !steps.is_empty() => {
            let count = requests
              .filter(item => {
                item is { "path": String(path), .. } && path == request.path()
              })
              .length()
            steps[(count - 1).min(steps.length() - 1)]
          }
          _ => route
        }
        let status = match route {
          { "status": Number(value, ..), .. } => value.to_int()
          _ => 200
        }
        let body = match route {
          { "json": value, .. } => @utf8.encode(value.stringify())
          _ => b""
        }
        let headers : Array[(String, String)] = []
        if route is { "headers": Object(fields), .. } {
          for key, value in fields {
            guard value is String(value) else { fail("header") }
            headers.push((key, value))
          }
        }
        Ok(
          @github.RawResponse::new(
            status~,
            headers~,
            body~,
            reason_phrase="Fixture",
          ),
        )
      }),
    )
    is Ok(client) else {
    fail("client")
  }
  guard @github_cli.parse(
      args.map(value => {
        match value {
          String(value) => value
          _ => fail("argument")
        }
      }),
    )
    is @github_cli.Business(options) else {
    fail("options")
  }
  guard @github_cli.RepositoryContext::parse("acme/widgets") is Ok(repository) else {
    fail("repository")
  }
  let result = @native.execute_github_business(
    options,
    client~,
    repository~,
    base_url="http://api.github.localhost",
  )
  assert_eq(result.stdout(), stdout)
  assert_eq(result.stderr(), stderr)
  assert_eq(result.exit_code(), exit_code.to_int())
  fn protocol(items : Array[Json]) -> Array[Json] raise {
    items.map(item => {
      guard item is { "method": verb, "path": path, "json_body": body, .. } else {
        fail("protocol record")
      }
      Json::object({ "method": verb, "path": path, "body": body })
    })
  }
  assert_eq(protocol(requests), protocol(expected))
}
