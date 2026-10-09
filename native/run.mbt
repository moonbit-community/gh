///|
/// Native CLI composition. argv excludes the executable name. Credentials
/// remain in the auth adapter; argument parsing never receives token values.
pub async fn run(args : Array[String]) -> @cli.Output {
  let host_env = @env.get_env_var("MOONHUB_HOST")
  let repo_env = @env.get_env_var("MOONHUB_REPO")
  let invocation = match @cli.parse(args, host_env?, repo_env?) {
    Ok(invocation) => invocation
    Err(message) =>
      return @cli.argument_error(message, json=args.contains("--json"))
  }
  match invocation {
    @cli.Help(text) => { stdout: text, stderr: "", exit_code: 0, }
    @cli.Version => { stdout: @cli.version() + "\n", stderr: "", exit_code: 0, }
    @cli.Trace(options) =>
      @cli.trace_output(
        read_trace(options.path, query=options.query),
        json=options.json,
      )
    @cli.Run(options) => {
      let outcome = if options.is_mutation() {
        Some(@moonhub.NotSent)
      } else {
        None
      }
      let config_path = options.config_path
      let trace_path = options.trace_path
      let read_retry = match
        @moonhub.ReadRetryPolicy::new(max_attempts=options.max_attempts) {
        Ok(policy) => policy
        Err(kind) =>
          return @cli.failure_output(
            @gh.ApiFailure::new(kind~),
            json=options.json,
            outcome?,
          )
      }
      let client = match
        client(
          base_url=options.base_url,
          config_path?,
          trace_path?,
          read_retry~,
        ) {
        Ok(client) => client
        Err(kind) =>
          return @cli.failure_output(
            @gh.ApiFailure::new(kind~),
            json=options.json,
            outcome?,
          )
      }
      let body = match load_body(options.body_input) {
        Ok(body) => body
        Err(kind) =>
          return @cli.failure_output(
            @gh.ApiFailure::new(kind~),
            json=options.json,
            outcome?,
          )
      }
      guard @env.rand(16) is Some(bytes) else {
        return @cli.failure_output(
          @gh.ApiFailure::new(
            kind=@gh.InvalidRequest(
              message="cannot create operation identifier",
            ),
          ),
          json=options.json,
          outcome?,
        )
      }
      let operation_id = "cli-" +
        bytes.to_array().map(byte => byte.to_int().to_string()).join("-")
      @cli.run(options, client, operation_id~, body?)
    }
  }
}
