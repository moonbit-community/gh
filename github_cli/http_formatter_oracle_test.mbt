// Generated from fixed gh HTTP-response formatter captures.

///|
test "pipe http-401-jq" {
  let result = @github_cli.render_response(
    401,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"message\":\"Bad credentials\",\"status\":\"401\"}"),
    jq=".message",
    format_context=@github_cli.FormatContext::new(
      terminal=false,
      color=false,
      width=40,
    ),
  )
  assert_eq(
    result.stdout(),
    "{\"message\":\"Bad credentials\",\"status\":\"401\"}",
  )
  assert_eq(result.stderr(), "gh: Bad credentials (HTTP 401)\n")
  assert_eq(result.exit_code(), 1)
}

///|
test "pipe http-403-template" {
  let result = @github_cli.render_response(
    403,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"message\":\"Resource not accessible\",\"status\":\"403\"}"),
    template="{{.message}}",
    format_context=@github_cli.FormatContext::new(
      terminal=false,
      color=false,
      width=40,
    ),
  )
  assert_eq(
    result.stdout(),
    "{\"message\":\"Resource not accessible\",\"status\":\"403\"}",
  )
  assert_eq(result.stderr(), "gh: Resource not accessible (HTTP 403)\n")
  assert_eq(result.exit_code(), 1)
}

///|
test "pipe http-404-invalid-jq" {
  let result = @github_cli.render_response(
    404,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"message\":\"Not Found\"}"),
    jq=".[",
    format_context=@github_cli.FormatContext::new(
      terminal=false,
      color=false,
      width=40,
    ),
  )
  assert_eq(result.stdout(), "{\"message\":\"Not Found\"}")
  assert_eq(result.stderr(), "gh: Not Found (HTTP 404)\n")
  assert_eq(result.exit_code(), 1)
}

///|
test "pipe http-422-errors" {
  let result = @github_cli.render_response(
    422,
    [("Content-Type", "application/json")],
    @utf8.encode(
      "{\"message\":\"Validation Failed\",\"errors\":[{\"resource\":\"Issue\",\"field\":\"title\",\"code\":\"missing_field\"}]}",
    ),
    jq=".message",
    format_context=@github_cli.FormatContext::new(
      terminal=false,
      color=false,
      width=40,
    ),
  )
  assert_eq(
    result.stdout(),
    "{\"message\":\"Validation Failed\",\"errors\":[{\"resource\":\"Issue\",\"field\":\"title\",\"code\":\"missing_field\"}]}",
  )
  assert_eq(result.stderr(), "gh: Validation Failed (HTTP 422)\n")
  assert_eq(result.exit_code(), 1)
}

///|
test "pipe http-500-missing-message" {
  let result = @github_cli.render_response(
    500,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"error\":\"oops\"}"),
    template="{{.error}}",
    format_context=@github_cli.FormatContext::new(
      terminal=false,
      color=false,
      width=40,
    ),
  )
  assert_eq(result.stdout(), "oops")
  assert_eq(result.stderr(), "gh: HTTP 500\n")
  assert_eq(result.exit_code(), 1)
}

///|
test "pipe http-403-control" {
  let result = @github_cli.render_response(
    403,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"message\":\"No\\u001b[31m access\"}"),
    jq=".",
    format_context=@github_cli.FormatContext::new(
      terminal=false,
      color=false,
      width=40,
    ),
  )
  assert_eq(result.stdout(), "{\"message\":\"No^[[31m access\"}")
  assert_eq(result.stderr(), "gh: No^[[31m access (HTTP 403)\n")
  assert_eq(result.exit_code(), 1)
}

///|
test "pipe http-success-empty-jq" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"a\":\"x\",\"b\":null}"),
    jq="",
    format_context=@github_cli.FormatContext::new(
      terminal=false,
      color=false,
      width=40,
    ),
  )
  assert_eq(result.stdout(), "{\"a\":\"x\",\"b\":null}")
  assert_eq(result.stderr(), "")
  assert_eq(result.exit_code(), 0)
}

///|
test "pipe http-success-empty-template" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"a\":\"x\",\"b\":null}"),
    template="",
    format_context=@github_cli.FormatContext::new(
      terminal=false,
      color=false,
      width=40,
    ),
  )
  assert_eq(result.stdout(), "{\"a\":\"x\",\"b\":null}")
  assert_eq(result.stderr(), "")
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY http-401-jq" {
  let result = @github_cli.render_response(
    401,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"message\":\"Bad credentials\",\"status\":\"401\"}"),
    jq=".message",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "\u001b[1;37m{\u001b[m\n  \u001b[1;34m\"message\"\u001b[m\u001b[1;37m:\u001b[m \u001b[32m\"Bad credentials\"\u001b[m\u001b[1;37m,\u001b[m\n  \u001b[1;34m\"status\"\u001b[m\u001b[1;37m:\u001b[m \u001b[32m\"401\"\u001b[m\n\u001b[1;37m}\u001b[m\ngh: Bad credentials (HTTP 401)\n",
  )
  assert_eq(result.exit_code(), 1)
}

///|
test "PTY http-403-template" {
  let result = @github_cli.render_response(
    403,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"message\":\"Resource not accessible\",\"status\":\"403\"}"),
    template="{{.message}}",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "\u001b[1;37m{\u001b[m\n  \u001b[1;34m\"message\"\u001b[m\u001b[1;37m:\u001b[m \u001b[32m\"Resource not accessible\"\u001b[m\u001b[1;37m,\u001b[m\n  \u001b[1;34m\"status\"\u001b[m\u001b[1;37m:\u001b[m \u001b[32m\"403\"\u001b[m\n\u001b[1;37m}\u001b[m\ngh: Resource not accessible (HTTP 403)\n",
  )
  assert_eq(result.exit_code(), 1)
}

///|
test "PTY http-404-invalid-jq" {
  let result = @github_cli.render_response(
    404,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"message\":\"Not Found\"}"),
    jq=".[",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "\u001b[1;37m{\u001b[m\n  \u001b[1;34m\"message\"\u001b[m\u001b[1;37m:\u001b[m \u001b[32m\"Not Found\"\u001b[m\n\u001b[1;37m}\u001b[m\ngh: Not Found (HTTP 404)\n",
  )
  assert_eq(result.exit_code(), 1)
}

///|
test "PTY http-422-errors" {
  let result = @github_cli.render_response(
    422,
    [("Content-Type", "application/json")],
    @utf8.encode(
      "{\"message\":\"Validation Failed\",\"errors\":[{\"resource\":\"Issue\",\"field\":\"title\",\"code\":\"missing_field\"}]}",
    ),
    jq=".message",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "\u001b[1;37m{\u001b[m\n  \u001b[1;34m\"message\"\u001b[m\u001b[1;37m:\u001b[m \u001b[32m\"Validation Failed\"\u001b[m\u001b[1;37m,\u001b[m\n  \u001b[1;34m\"errors\"\u001b[m\u001b[1;37m:\u001b[m \u001b[1;37m[\u001b[m\n    \u001b[1;37m{\u001b[m\n      \u001b[1;34m\"resource\"\u001b[m\u001b[1;37m:\u001b[m \u001b[32m\"Issue\"\u001b[m\u001b[1;37m,\u001b[m\n      \u001b[1;34m\"field\"\u001b[m\u001b[1;37m:\u001b[m \u001b[32m\"title\"\u001b[m\u001b[1;37m,\u001b[m\n      \u001b[1;34m\"code\"\u001b[m\u001b[1;37m:\u001b[m \u001b[32m\"missing_field\"\u001b[m\n    \u001b[1;37m}\u001b[m\n  \u001b[1;37m]\u001b[m\n\u001b[1;37m}\u001b[m\ngh: Validation Failed (HTTP 422)\n",
  )
  assert_eq(result.exit_code(), 1)
}

///|
test "PTY http-500-missing-message" {
  let result = @github_cli.render_response(
    500,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"error\":\"oops\"}"),
    template="{{.error}}",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(result.stdout() + result.stderr(), "oopsgh: HTTP 500\n")
  assert_eq(result.exit_code(), 1)
}

///|
test "PTY http-403-control" {
  let result = @github_cli.render_response(
    403,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"message\":\"No\\u001b[31m access\"}"),
    jq=".",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "\u001b[1;37m{\u001b[m\n  \u001b[1;34m\"message\"\u001b[m\u001b[1;37m:\u001b[m \u001b[32m\"No^[[31m access\"\u001b[m\n\u001b[1;37m}\u001b[m\ngh: No^[[31m access (HTTP 403)\n",
  )
  assert_eq(result.exit_code(), 1)
}

///|
test "PTY http-success-empty-jq" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"a\":\"x\",\"b\":null}"),
    jq="",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "\u001b[1;37m{\u001b[m\n  \u001b[1;34m\"a\"\u001b[m\u001b[1;37m:\u001b[m \u001b[32m\"x\"\u001b[m\u001b[1;37m,\u001b[m\n  \u001b[1;34m\"b\"\u001b[m\u001b[1;37m:\u001b[m \u001b[36mnull\u001b[m\n\u001b[1;37m}\u001b[m\n",
  )
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY http-success-empty-template" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"a\":\"x\",\"b\":null}"),
    template="",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "\u001b[1;37m{\u001b[m\n  \u001b[1;34m\"a\"\u001b[m\u001b[1;37m:\u001b[m \u001b[32m\"x\"\u001b[m\u001b[1;37m,\u001b[m\n  \u001b[1;34m\"b\"\u001b[m\u001b[1;37m:\u001b[m \u001b[36mnull\u001b[m\n\u001b[1;37m}\u001b[m\n",
  )
  assert_eq(result.exit_code(), 0)
}
