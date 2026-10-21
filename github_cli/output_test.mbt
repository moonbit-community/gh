///|
test "output preserves binary bytes" {
  let bytes = Bytes::from_array([0, 255])
  let output = @github_cli.Output::from_bytes(bytes)
  assert_true(Bytes::equal(output.stdout_bytes(), bytes))
  assert_eq(output.exit_code(), 0)
}

///|
test "raw response preserves binary body and separates HTTP error" {
  let bytes = Bytes::from_array([0, 255, 1])
  let output = @github_cli.render_response(404, [], bytes)
  assert_true(Bytes::equal(output.stdout_bytes(), bytes))
  assert_eq(output.stderr(), "gh: HTTP 404\n")
  assert_eq(output.exit_code(), 1)
}

///|
test "HTTP JSON error message is rendered on stderr while body stays raw" {
  let body = @utf8.encode(
    "{\"message\":\"Bad credentials\",\"status\":\"401\"}",
  )
  let output = @github_cli.render_response(401, [], body)
  assert_eq(output.stdout_bytes(), body)
  assert_eq(output.stderr(), "gh: Bad credentials (HTTP 401)\n")
  assert_eq(output.exit_code(), 1)
}

///|
test "successful non UTF-8 responses remain byte preserving" {
  let bytes = Bytes::from_array([255, 1, 2])
  let output = @github_cli.render_response(200, [], bytes)
  assert_true(Bytes::equal(output.stdout_bytes(), bytes))
  assert_eq(output.exit_code(), 0)
}

///|
test "include remains visible with silent" {
  let output = @github_cli.render_response(
    200,
    [("X-Test", "yes")],
    @utf8.encode("body"),
    include_headers=true,
    silent=true,
  )
  assert_eq(output.stdout(), "HTTP/1.1 200 OK\nX-Test: yes\n\n")
}

///|
test "jq arrays nested fields and missing fields" {
  let body = @utf8.encode("[{\"name\":\"one\"},{\"other\":2}]")
  assert_eq(
    @github_cli.render_response(200, [], body, jq=".[].name").stdout(),
    "one\n\n",
  )
  let object = @utf8.encode("{\"a\":{\"b\":3}}")
  assert_eq(
    @github_cli.render_response(200, [], object, jq=".a.b").stdout(),
    "3\n",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq="length").stdout(),
    "2\n",
  )
}

///|
test "jq and template reject malformed syntax" {
  let body = @utf8.encode("{\"name\":\"one\"}")
  let jq = @github_cli.render_response(200, [], body, jq="select(")
  assert_eq(jq.exit_code(), 1)
  let template = @github_cli.render_response(
    200,
    [],
    body,
    template="x{{range .}}",
  )
  assert_eq(template.exit_code(), 1)
  assert_eq(template.stderr(), "template: :1: unexpected EOF\n")
}

///|
test "jq supports predicates, constructors, and format filters" {
  let body = @utf8.encode(
    "[{\"name\":\"one\",\"state\":\"open\"},{\"name\":\"two\",\"state\":\"closed\"}]",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      body,
      jq="map(select(.state == \"open\")) | .[] | {name: .name, state: .state}",
    ).stdout(),
    "{\"name\":\"one\",\"state\":\"open\"}\n",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      body,
      jq="map(select(.state == \"open\")) | .[] | {name, state}",
    ).stdout(),
    "{\"name\":\"one\",\"state\":\"open\"}\n",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      @utf8.encode("[\"one\",\"two\"]"),
      jq="join(\",\")",
    ).stdout(),
    "one,two\n",
  )
}

///|
test "template supports printf, join, with, and else" {
  let body = @utf8.encode(
    "{\"name\":\"one\",\"enabled\":false,\"labels\":[\"bug\",\"help wanted\"]}",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      body,
      template="{{printf \"%s: %s\" .name .name}} {{join \",\" .labels}} {{if .enabled}}yes{{else}}no{{end}}",
    ).stdout(),
    "one: one bug,help wanted no",
  )
}

///|
test "template retains literal prefix and suffix" {
  let body = @utf8.encode("{\"name\":\"one\"}")
  let output = @github_cli.render_response(
    200,
    [],
    body,
    template="pre {{.name}} post",
  )
  assert_eq(output.stdout(), "pre one post")
}

///|
test "template supports predicates and gh Sprig argument order, rejecting unregistered functions" {
  let body = @utf8.encode(
    "{\"state\":\"open\",\"title\":\"Fix issue\",\"labels\":[\"bug\"]}",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      body,
      template="{{if eq .state \"open\"}}{{.title}}{{else}}closed{{end}}",
    ).stdout(),
    "Fix issue",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, template="{{toJSON}}").stderr(),
    "template: :1: function \"toJSON\" not defined\n",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      body,
      template="{{contains \"Fix\" .title}} {{hasPrefix \"Fix\" .title}} {{hasSuffix \"issue\" .title}}",
    ).stdout(),
    "true true true",
  )
}

///|
test "template supports gh color, truncation, hyperlink, and table helpers" {
  let body = @utf8.encode(
    "{\"url\":\"https://example.test\",\"title\":\"abcdefgh\",\"state\":\"open\"}",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      body,
      template="{{truncate 5 .title}}|{{hyperlink .url .title}}|{{autocolor \"green\" .state}}|{{tablerow .state .title}}{{tablerender}}",
    ).stdout(),
    "ab...|\u001b]8;;https://example.test\u001b\\abcdefgh\u001b]8;;\u001b\\|open|open  abcdefgh\n",
  )
  let colored = @github_cli.render_response(
    200,
    [],
    body,
    template="{{color \"green\" .state}}",
    allow_escape_sequences=true,
    format_context=@github_cli.FormatContext::new(terminal=true, color=true),
  ).stdout()
  assert_true(colored.contains("\u{001b}[0;32mopen\u{001b}[0m"))
}

///|
test "jq pipelines and templates cover common gh filters" {
  let body = @utf8.encode(
    "{\"items\":[{\"name\":\"one\"},{\"name\":\"two\"}],\"enabled\":true}",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq=".items[] | .name").stdout(),
    "one\ntwo\n",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      body,
      template="{{range .items}}{{.name}}{{\"\\n\"}}{{end}}",
    ).stdout(),
    "one\ntwo\n",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq=".missing // \"fallback\"").stdout(),
    "fallback\n",
  )
}

///|
test "escape sequences are sanitized by default" {
  let body = @utf8.encode("\u{001b}[31mred\u{001b}[0m")
  let output = @github_cli.render_response(200, [], body)
  assert_eq(output.stdout(), "^[[31mred^[[0m")
  let escaped = @github_cli.render_response(
    200,
    [],
    body,
    allow_escape_sequences=true,
  )
  assert_eq(escaped.stdout_bytes(), body)
}

///|
test "jq supports quoted object selectors and collection helpers" {
  let body = @utf8.encode(
    "{\"display_name\":\"demo\",\"items\":[1,2],\"meta\":{\"state\":\"open\"}}",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq=".[\"display_name\"]").stdout(),
    "demo\n",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq=".meta | keys").stdout(),
    "[\"state\"]\n",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq=".meta | to_entries").stdout(),
    "[{\"key\":\"state\",\"value\":\"open\"}]\n",
  )
}

///|
test "jq csv escapes commas and quotes" {
  let body = @utf8.encode("[\"one,two\",\"say \\\"hi\\\"\"]")
  assert_eq(
    @github_cli.render_response(200, [], body, jq="@csv").stdout(),
    "\"one,two\",\"say \"\"hi\"\"\"\n",
  )
}

///|
test "jq core filters cover optional lookups, range, predicates, and folds" {
  let body = @utf8.encode(
    "{\"name\":\"Moon Bit\",\"items\":[1,[2,3],2],\"meta\":{\"ready\":true}}",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      body,
      jq=".missing?.value // \"fallback\"",
    ).stdout(),
    "fallback\n",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq="range(2;5)").stdout(),
    "2\n3\n4\n",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq=".meta | has(\"ready\")").stdout(),
    "true\n",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      body,
      jq=".name | startswith(\"Moon\")",
    ).stdout(),
    "true\n",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq=".items | flatten | add").stdout(),
    "8\n",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      @utf8.encode("{\"ready\":true,\"draft\":false}"),
      jq="select(.ready and .draft == false)",
    ).stdout(),
    "{\"draft\":false,\"ready\":true}\n",
  )
  assert_eq(
    @github_cli.render_response(200, [], @utf8.encode("null"), jq="length").stdout(),
    "0\n",
  )
}

///|
test "jq predicates honor boolean precedence and quoted operators" {
  let body = @utf8.encode(
    "[{\"state\":\"open\",\"draft\":false},{\"state\":\"closed\",\"draft\":false},{\"state\":\"open\",\"draft\":true}]",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      body,
      jq="map(select(.state == \"open\" and .draft == false)) | .[] | .state",
    ).stdout(),
    "open\n",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      @utf8.encode("{\"value\":\"rock or roll\"}"),
      jq="select(.value == \"rock or roll\") | .value",
    ).stdout(),
    "rock or roll\n",
  )
}

///|
test "jq sort unique map_values and URI/text format filters" {
  let body = @utf8.encode(
    "{\"values\":[3,1,3,2],\"counts\":{\"a\":1,\"b\":2},\"text\":\"a b/c\"}",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq=".values | sort | unique").stdout(),
    "[1,2,3]\n",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq=".counts | map_values(. + 1)").stdout(),
    "{\"a\":2,\"b\":3}\n",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq=".text | @uri").stdout(),
    "a%20b%2Fc\n",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq=".text | @text").stdout(),
    "a b/c\n",
  )
  assert_eq(
    @github_cli.render_response(200, [], body, jq=".text | @base64").stdout(),
    "YSBiL2M=\n",
  )
  assert_eq(
    @github_cli.render_response(
      200,
      [],
      @utf8.encode("\"YSBiL2M=\""),
      jq="@base64d",
    ).stdout(),
    "a b/c\n",
  )
}
