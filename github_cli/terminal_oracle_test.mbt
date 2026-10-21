// Generated from the pinned PTY corpus. The actual PTY runner compares raw CRLF;
// these portable renderer tests account only for the terminal driver's LF to CRLF conversion.

///|
test "PTY oracle terminal-object" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("{\"z\":[1,2],\"a\":true}"),
    jq=".",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "\u001b[1;38m{\u001b[m\n  \u001b[1;34m\"a\"\u001b[m\u001b[1;38m:\u001b[m \u001b[33mtrue\u001b[m\u001b[1;38m,\u001b[m\n  \u001b[1;34m\"z\"\u001b[m\u001b[1;38m:\u001b[m \u001b[1;38m[\u001b[m\n    1\u001b[1;38m,\u001b[m\n    2\n  \u001b[1;38m]\u001b[m\n\u001b[1;38m}\u001b[m\n",
  )
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY oracle terminal-json-types" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode(
      "{\"empty\":null,\"f\":false,\"s\":\"a\\\"b\\n😀\",\"n\":-1.25,\"arr\":[null,\"s\"]}",
    ),
    jq=".",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "\u001b[1;38m{\u001b[m\n  \u001b[1;34m\"arr\"\u001b[m\u001b[1;38m:\u001b[m \u001b[1;38m[\u001b[m\n    \u001b[36mnull\u001b[m\u001b[1;38m,\u001b[m\n    \u001b[32m\"s\"\u001b[m\n  \u001b[1;38m]\u001b[m\u001b[1;38m,\u001b[m\n  \u001b[1;34m\"empty\"\u001b[m\u001b[1;38m:\u001b[m \u001b[36mnull\u001b[m\u001b[1;38m,\u001b[m\n  \u001b[1;34m\"f\"\u001b[m\u001b[1;38m:\u001b[m \u001b[33mfalse\u001b[m\u001b[1;38m,\u001b[m\n  \u001b[1;34m\"n\"\u001b[m\u001b[1;38m:\u001b[m -1.25\u001b[1;38m,\u001b[m\n  \u001b[1;34m\"s\"\u001b[m\u001b[1;38m:\u001b[m \u001b[32m\"a\\\"b\\n😀\"\u001b[m\n\u001b[1;38m}\u001b[m\n",
  )
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY oracle terminal-color-styles" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("\"x\""),
    template="{{color \"cyan+bud:blue+h\" .}}|{{color \"202:17\" .}}|{{color \"off\" .}}|{{color \"reset\" .}}|{{color \"unknown\" .}}",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "\u001b[0;1;2;4;36;104mx\u001b[0m|\u001b[0;38;5;202;48;5;17mx\u001b[0m|x\u001b[0m|\u001b[0mx\u001b[0m|\u001b[0;30mx\u001b[0m",
  )
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY oracle terminal-scalar-stream" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("[\"中文😀\",1.005,null]"),
    jq=".[]",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(result.stdout() + result.stderr(), "中文😀\n1.00\n\n")
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY oracle terminal-partial-error" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("[{\"x\":\"ok\"},3]"),
    jq=".[] | .x",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "ok\nexpected an object but got: number (3)\n",
  )
  assert_eq(result.exit_code(), 1)
}

///|
test "PTY oracle terminal-color" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("\"Moon\""),
    template="{{color \"red+b\" .}}",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(result.stdout() + result.stderr(), "\u001b[0;1;31mMoon\u001b[0m")
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY oracle terminal-autocolor" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("\"Moon\""),
    template="{{autocolor \"red\" .}}",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(result.stdout() + result.stderr(), "\u001b[0;31mMoon\u001b[0m")
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY oracle terminal-hyperlink" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("\"Moon\""),
    template="{{hyperlink \"https://example.com/\" .}}",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "\u001b]8;;https://example.com/\u001b\\Moon\u001b]8;;\u001b\\",
  )
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY oracle terminal-narrow-table" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode(
      "[[\"one-very-long-value-in-first-column\",\"another-long-value-in-second-column\"],[\"short\",\"tail\"]]",
    ),
    template="{{range .}}{{tablerow (index . 0) (index . 1)}}{{end}}",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "one-very-long-va...  another-long-val...\nshort                tail\n",
  )
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY oracle terminal-three-columns" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode(
      "[[\"name\",\"012345678901234567890123456789\",\"end\"],[\"中文测试\",\"abc\",\"last\"]]",
    ),
    template="{{range .}}{{tablerow (index . 0) (index . 1) (index . 2)}}{{end}}",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "name      012345678901234567890...  end\n中文测试  abc                       last\n",
  )
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY oracle terminal-uneven-rows" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("{}"),
    template="{{tablerow \"a\" \"b\"}}{{tablerow \"long\"}}{{tablerender}}",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(result.stdout() + result.stderr(), "a     b\nlong\n")
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY oracle terminal-untrusted-escape" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("\"a\\u001b[31mb\\u001b[0m\""),
    jq=".",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(result.stdout() + result.stderr(), "a^[[31mb^[[0m\n")
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY oracle terminal-template-escape" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("\"a\\u001b[31mb\\u001b[0m\""),
    template="{{.}}",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(result.stdout() + result.stderr(), "a^[[31mb^[[0m")
  assert_eq(result.exit_code(), 0)
}

///|
test "PTY oracle terminal-error-location" {
  let result = @github_cli.render_response(
    200,
    [("Content-Type", "application/json")],
    @utf8.encode("[]"),
    template="ok\n{{printf \"%s\" (index . 1)}}",
    format_context=@github_cli.FormatContext::new(
      terminal=true,
      color=true,
      width=40,
    ),
  )
  assert_eq(
    result.stdout() + result.stderr(),
    "ok\ntemplate: :2:15: executing \"\" at <index . 1>: error calling index: index out of range: 1\n",
  )
  assert_eq(result.exit_code(), 1)
}
