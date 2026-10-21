// Generated from the pinned oracle corpus by scripts/formatter_tests.mbtx.

///|
test "identity" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"z\":2,\"a\":[true,null,\"x\"]}"),
    ".",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{\"a\":[true,null,\"x\"],\"z\":2}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "scalar-decimals" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse(
      "[1.005,2.675,-1.005,0.0001,0,100000000000000000000,0.125,0.375]",
    ),
    ".[]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "1.00\n2.67\n-1.00\n0.00\n0\n100000000000000000000\n0.12\n0.38\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "empty-and-null" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[null,false,\"\",\"中文😀\"]"),
    ".[]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "\nfalse\n\n中文😀\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "empty-filter" {
  let (stdout, error) = @formatter_jq.render(@json.parse("[1,2]"), "empty", environment={
    "LANG": "C",
    "TZ": "UTC",
  })
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "object-sort" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"z\":3,\"a\":1,\"b\":2}"),
    ".",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{\"a\":1,\"b\":2,\"z\":3}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "construct-sort" {
  let (stdout, error) = @formatter_jq.render(@json.parse("{}"), "{z:2,a:1}", environment={
    "LANG": "C",
    "TZ": "UTC",
  })
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{\"a\":1,\"z\":2}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "reduce" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2,3]"),
    "reduce .[] as $x (0; . + $x)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "6\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "assignment" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"a\":1,\"b\":2}"),
    ".a += 3",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{\"a\":4,\"b\":2}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "conditional" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[0,1,2,3]"),
    ".[] | if . % 2 == 0 then . * 10 else empty end",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "0\n20\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "definitions" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2]"),
    "def twice: . * 2; map(twice)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[2,4]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "interpolation" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"name\":\"中文\",\"number\":3}"),
    "\"\\(.name): \\(.number)\"",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "中文: 3\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "unicode-length" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a😀中文\""),
    "length, explode",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "4\n[97,128512,20013,25991]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "negative-index" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2,3]"),
    ".[-1], .[1:3]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "3\n[2,3]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "missing-field" {
  let (stdout, error) = @formatter_jq.render(@json.parse("{}"), ".missing", environment={
    "LANG": "C",
    "TZ": "UTC",
  })
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "scalar-field-error" {
  let (stdout, error) = @formatter_jq.render(@json.parse("1"), ".name", environment={
    "LANG": "C",
    "TZ": "UTC",
  })
  assert_eq(
    error.map_or("", message => message + "\n"),
    "expected an object but got: number (1)\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "array-field-error" {
  let (stdout, error) = @formatter_jq.render(@json.parse("[1]"), ".name", environment={
    "LANG": "C",
    "TZ": "UTC",
  })
  assert_eq(
    error.map_or("", message => message + "\n"),
    "expected an object but got: array ([1])\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "null-iteration-error" {
  let (stdout, error) = @formatter_jq.render(@json.parse("null"), ".[]", environment={
    "LANG": "C",
    "TZ": "UTC",
  })
  assert_eq(
    error.map_or("", message => message + "\n"),
    "cannot iterate over: null\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "partial-failure" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[{\"name\":\"ok\"},1,{\"name\":\"later\"}]"),
    ".[] | .name",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "expected an object but got: number (1)\n",
  )
  assert_eq(stdout, "ok\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "explicit-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "1, error(\"fixture failure\"), 2",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "error: fixture failure\n",
  )
  assert_eq(stdout, "1\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "try-catch" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("1"),
    "try .name catch .",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "expected an object but got: number (1)\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "optional-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,{\"name\":\"ok\"}]"),
    ".[] | .name?",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "ok\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "parse-error" {
  let (stdout, error) = @formatter_jq.render(@json.parse("{}"), "select(", environment={
    "LANG": "C",
    "TZ": "UTC",
  })
  assert_eq(
    error.map_or("", message => message + "\n"),
    "failed to parse jq expression (line 1, column 8)\n    select(\n           ^  unexpected EOF\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "unknown-function" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{}"),
    "not_a_function",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "function not defined: not_a_function/0\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "array-map-values" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2,3]"),
    "map_values(. + 1)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[2,3,4]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "object-values" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"b\":2,\"a\":1}"),
    "values",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{\"a\":1,\"b\":2}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "csv" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[\"a,b\",\"c\\\"d\",null,true,3]"),
    "@csv",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "\"a,b\",\"c\"\"d\",,true,3\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-compile-before-output" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{}"),
    "1, not_a_function",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "function not defined: not_a_function/0\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "jq-divide-zero" {
  let (stdout, error) = @formatter_jq.render(@json.parse("{}"), "1 / 0", environment={
    "LANG": "C",
    "TZ": "UTC",
  })
  assert_eq(
    error.map_or("", message => message + "\n"),
    "cannot divide number (1) by: number (0)\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "jq-syntax-token" {
  let (stdout, error) = @formatter_jq.render(@json.parse("{}"), ". + )", environment={
    "LANG": "C",
    "TZ": "UTC",
  })
  assert_eq(
    error.map_or("", message => message + "\n"),
    "failed to parse jq expression (line 1, column 5)\n    . + )\n        ^  unexpected token \")\"\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "jq-empty-expression" {
  let (stdout, error) = @formatter_jq.render(@json.parse("{}"), "", environment={
    "LANG": "C",
    "TZ": "UTC",
  })
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{}")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-nested-catch" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,{\"name\":\"ok\"}]"),
    "map(try .name catch .)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[\"expected an object but got: number (1)\",\"ok\"]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-string-slice" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a😀中文\""),
    ".[1:3]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "😀中\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-sort-numbers" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[20,3,-1,10,2]"),
    "sort",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[-1,2,3,10,20]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-group" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[{\"x\":2},{\"x\":1},{\"x\":2}]"),
    "group_by(.x)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[[{\"x\":1}],[{\"x\":2},{\"x\":2}]]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-delpaths" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"a\":1,\"b\":2}"),
    "delpaths([[\"a\"]])",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{\"b\":2}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-try-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{}"),
    "try error(\"fixture\") catch .",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "fixture\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-json-escape" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"html\":\"<>&\",\"line\":\"x y\"}"),
    ".",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "{\"html\":\"\\u003c\\u003e\\u0026\",\"line\":\"x\\u2028y\"}\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-env" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{}"),
    "env.LANG, $ENV.TZ",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "C\nUTC\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-select-stream" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2,3]"),
    ".[] | select(. > 1) | tostring",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "2\n3\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-array-cartesian" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{}"),
    "{a:(1,2), b:(3,4)}",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "{\"a\":1,\"b\":3}\n{\"a\":1,\"b\":4}\n{\"a\":2,\"b\":3}\n{\"a\":2,\"b\":4}\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-sort-by" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[{\"a\":2,\"b\":1},{\"a\":1,\"b\":2},{\"a\":1,\"b\":1}]"),
    "sort_by(.a,.b)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[{\"a\":1,\"b\":1},{\"a\":1,\"b\":2},{\"a\":2,\"b\":1}]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-unique-by" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[{\"a\":2},{\"a\":1},{\"a\":2}]"),
    "unique_by(.a)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[{\"a\":1},{\"a\":2}]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-regex-capture" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"abc123\""),
    "capture(\"(?<letters>[a-z]+)(?<digits>[0-9]+)\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{\"digits\":\"123\",\"letters\":\"abc\"}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-foreach" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2,3]"),
    "foreach .[] as $x (0; . + $x; . * 2)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "2\n6\n12\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-label-break" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2,3]"),
    "label $out | .[] | if . == 2 then break $out else . end",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "1\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-numeric-type" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,1.5,null]"),
    ".[] | type",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "number\nnumber\nnull\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-error-object" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{}"),
    "try error({a:1}) catch .",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{\"a\":1}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "jq-parser-multiline" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{}"),
    ". |\nselect(",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "failed to parse jq expression (line 2, column 8)\n    select(\n           ^  unexpected EOF\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "regex-match" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"abc123def\""),
    "match(\"[0-9]+\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "{\"captures\":[],\"length\":3,\"offset\":3,\"string\":\"123\"}\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-captures-unicode" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"😀A12x\""),
    "match(\"(?<letters>[A-Z]+)([0-9]+)(?<missing>z)?\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "{\"captures\":[{\"length\":1,\"name\":\"letters\",\"offset\":1,\"string\":\"A\"},{\"length\":2,\"name\":null,\"offset\":2,\"string\":\"12\"},{\"length\":0,\"name\":\"missing\",\"offset\":-1,\"string\":null}],\"length\":3,\"offset\":1,\"string\":\"A12\"}\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-global-match" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"aba\""),
    "[match(\"a\";\"g\")]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "[{\"captures\":[],\"length\":1,\"offset\":0,\"string\":\"a\"},{\"captures\":[],\"length\":1,\"offset\":2,\"string\":\"a\"}]\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-case-insensitive" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"AbC\""),
    "test(\"abc\";\"i\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "true\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-dynamic-pattern" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"pattern\":\"[0-9]+\",\"value\":\"a12\"}"),
    ".pattern as $p | .value | test($p)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "true\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-scan" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a12b3\""),
    "[scan(\"[0-9]+\")]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[\"12\",\"3\"]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-scan-groups" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a12b3\""),
    "[scan(\"([a-z])([0-9]+)\")]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[[\"a\",\"12\"],[\"b\",\"3\"]]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-capture-global" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"A a\""),
    "[capture(\"(?<x>a)(?<z>z)?\";\"gi\")]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[{\"x\":\"A\",\"z\":null},{\"x\":\"a\",\"z\":null}]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-splits" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a,,b;c;\""),
    "[splits(\"[,;]+\")]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[\"a\",\"b\",\"c\",\"\"]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-splits-empty" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"ab\""),
    "[splits(\"\")]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[\"\",\"a\",\"b\",\"\"]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-sub" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a12b3\""),
    "sub(\"[0-9]+\";\"N\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "aNb3\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-gsub" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a12b3\""),
    "gsub(\"[0-9]+\";\"N\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "aNbN\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-replacement-capture" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a12b3\""),
    "sub(\"(?<x>[0-9]+)\";\"<\\(.x)>\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "a<12>b3\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-replacement-expression" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a12b3\""),
    "gsub(\"(?<x>[0-9]+)\";(.x | tonumber | .+1 | tostring))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "a13b4\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-empty-matches" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"😀x\""),
    "[match(\"\";\"g\")]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "[{\"captures\":[],\"length\":0,\"offset\":0,\"string\":\"\"},{\"captures\":[],\"length\":0,\"offset\":1,\"string\":\"\"},{\"captures\":[],\"length\":0,\"offset\":2,\"string\":\"\"}]\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-anchor" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"aba\""),
    "gsub(\"^\";\"X\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "Xaba\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-word-boundaries" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a b\""),
    "gsub(\"\\\\b\";\"|\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "|a| |b|\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-invalid-flag" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a\""),
    "test(\"a\";\"z\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "unsupported regular expression flag: \"z\"\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "regex-invalid-pattern" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a\""),
    "test(\"[\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "invalid regular expression \"[\": error parsing regexp: missing closing ]: `[`\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "regex-default-lines" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a\\nb\""),
    "test(\"^b\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "false\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-m-lines" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a\\nb\""),
    "test(\"a.b\";\"m\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "true\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-s-lines" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a\\nb\""),
    "test(\"^b\";\"s\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "unsupported regular expression flag: \"s\"\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "regex-stream-replacement" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"aa\""),
    "gsub(\"a\";(\"x\",\"y\"))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "xx\nyy\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "number-conversions" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse(
      "[12,\"12\",\"-0\",\"01\",\"1e3\",\"+1\",\" 1 \",\"NaN\",\"nan\",\"inf\",\"\",true,null]",
    ),
    ".[] | try tonumber catch .",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "12\n12\n0\n1\n1000\n1\ntonumber cannot be applied to \" 1 \": invalid number\ntonumber cannot be applied to \"NaN\": invalid number\ntonumber cannot be applied to \"nan\": invalid number\ntonumber cannot be applied to \"inf\": invalid number\ntonumber cannot be applied to \"\": invalid number\ntonumber cannot be applied to: boolean (true)\ntonumber cannot be applied to: null\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "function-filter-argument" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2]"),
    "def each(f): .[] | f; each(. + 1)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "2\n3\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "function-value-argument" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("3"),
    "def add($n): . + $n; add(2)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "5\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "function-filter-stream" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("2"),
    "def collect(f): [f]; collect((., .+1))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[2,3]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "function-lexical-variable" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"x\":2}"),
    ".x as $x | def f: $x; 99 as $x | f",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "2\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "function-overload" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("3"),
    "def f: .+1; def f($x): .+$x; f, f(2)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "4\n5\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "function-value-streams" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "def combine($x;$y): [$x,$y]; combine((1,2);(3,4))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[1,3]\n[1,4]\n[2,3]\n[2,4]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "function-recursion" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "def count($n): if $n>0 then $n,count($n-1) else empty end; count(3)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "3\n2\n1\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "function-argument-closure" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("2"),
    "def f(g): 10 as $x | g; 5 as $x | f(.+$x)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "7\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "variable-compile-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "1, $missing",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "variable not defined: $missing\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "label-optional-array" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "[label $out | (1, (break $out)?, 2)]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[1]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "dynamic-index-string" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"key\":\"foo\",\"foo\":42}"),
    ".key as $key | .[$key]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "42\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "dynamic-index-array" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2,3]"),
    ".[(0,2)]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "1\n3\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "big-integer-literal" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "9007199254740993",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "9007199254740993\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "big-integer-arithmetic" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "9007199254740993 + 2",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "9007199254740995\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "big-integer-input-rounded" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("9007199254740993"),
    ".",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "9007199254740992\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "object-key-order-unicode" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"z\":1,\"abc\":2,\"😀\":3,\"\":4}"),
    "., keys",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "{\"abc\":2,\"z\":1,\"\":4,\"😀\":3}\n[\"abc\",\"z\",\"\",\"😀\"]\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-type-errors" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[null,1,true,[]]"),
    ".[] | try test(\"a\") catch .",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "test(\"a\"; null) cannot be applied to: null\ntest(\"a\"; null) cannot be applied to: number (1)\ntest(\"a\"; null) cannot be applied to: boolean (true)\ntest(\"a\"; null) cannot be applied to: array ([])\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-argument-errors" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"abc\""),
    "(try test(1) catch .), (try test(\"a\";1) catch .), (try sub(\"a\";1) catch .)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "test(1; null) cannot be applied to: string (\"abc\")\ntest(\"a\"; 1) cannot be applied to: string (\"abc\")\ncannot add: string (\"\") and number (1)\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-backreference-rejected" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"aa\""),
    "test(\"(a)\\\\1\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "invalid regular expression \"(a)\\\\1\": error parsing regexp: invalid escape sequence: `\\1`\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "regex-partial-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"aa\""),
    "match((\"a\",\"[\"))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "invalid regular expression \"[\": error parsing regexp: missing closing ]: `[`\n",
  )
  assert_eq(
    stdout, "{\"captures\":[],\"length\":1,\"offset\":0,\"string\":\"a\"}\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "regex-adjacent-empty" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"aba\""),
    "[match(\"a*\";\"g\")]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "[{\"captures\":[],\"length\":1,\"offset\":0,\"string\":\"a\"},{\"captures\":[],\"length\":1,\"offset\":2,\"string\":\"a\"}]\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "regex-replacement-variable-streams" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"ab\""),
    "gsub(\"(?<x>.)\"; if .x == \"a\" then \"A\",\"AA\" else \"B\" end)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "AB\nAA\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "function-value-partial-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "def f($x): $x; f((1,error(\"late\")))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "error: late\n")
  assert_eq(stdout, "1\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "function-body-partial-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "def f: 1,error(\"late\"); f",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "error: late\n")
  assert_eq(stdout, "1\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "function-filter-used-twice" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("3"),
    "def f(g): [g,g]; f((.,.+1))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[3,4,3,4]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "function-shadow-builtin" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2]"),
    "def length: 99; length",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "99\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "function-lexical-function" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "def f: 1; def g: f; def f: 2; g,f",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "1\n2\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "function-local-definition" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "(def f: 1; f), f",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "function not defined: f/0\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "function-param-not-outside" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "def f($x): $x; f(1),$x",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "variable not defined: $x\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "dynamic-index-original-input" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"key\":\"x\",\"a\":{\"x\":5}}"),
    ".a[.key]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "5\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "dynamic-index-cross-product" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[[1,2],[3,4]]"),
    ".[][(0,1)]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "1\n3\n2\n4\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "dynamic-negative-index" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2,3]"),
    "1 as $n | .[-$n]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "3\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "dynamic-invalid-index" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"x\":1}"),
    "(try .[true] catch .), (try .[{}] catch .), (try .[1] catch .)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "expected a string for object key but got: boolean (true)\nexpected \"start\" and \"end\" for slicing but got: object ({})\nexpected an array but got: object ({\"x\":1})\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "dynamic-path-update" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"x\":[1,2]}"),
    "\"x\" as $key | .[$key][1] += 4",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{\"x\":[1,6]}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "decimal-exponent-literals" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "[1e3,1E-2,-2.5e+1,.5,-.5,3-2,3--2,-0]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[1000,0.01,-25,0.5,-0.5,1,5,0]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "big-integer-containers" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "[9007199254740993,-9007199254740993,{x:999999999999999999999999999999}]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "[9007199254740993,-9007199254740993,{\"x\":999999999999999999999999999999}]\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "big-integer-ops" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "[9007199254740993-2,9007199254740993*3,9007199254740993%7,9007199254740993/3,9007199254740993>9007199254740992]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "[9007199254740991,27021597764222979,5,3002399751580331,true]\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "big-integer-mixed-input" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("1"),
    "9007199254740993 + .",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "9007199254740992\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "big-integer-tonumber" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"9007199254740993\""),
    "tonumber",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "9007199254740993\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "big-integer-fromjson" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"{\\\"x\\\":9007199254740993}\""),
    "fromjson",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{\"x\":9007199254740993}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "number-negative-builtins" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2,3]"),
    "(try nth(-1) catch .), (try limit(-1;.[]) catch .)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "3\nlimit doesn't support negative count\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "index-string-subsequence" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2,1,2,3]"),
    ".[[1,2]]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[0,2]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-array-catch" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "[try (1,error(\"late\")) catch .]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[1,\"late\"]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-array-optional" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "[(1,error(\"late\"))?]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[1]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-first-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "first(1,error(\"unreached\"))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "1\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-limit-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "limit(1;1,error(\"unreached\"))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "1\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-limit-zero" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "limit(0;error(\"unreached\"))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-repeat-limit" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("3"),
    "[limit(4;repeat(.,.+1))]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[3,4,3,4]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-select-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("7"),
    "select(true,error(\"late\"))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "error: late\n")
  assert_eq(stdout, "7\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "stream-operator-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "(1,error(\"late\")) + 2",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "error: late\n")
  assert_eq(stdout, "3\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "stream-alternative-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "(1,error(\"late\")) // 2",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "error: late\n")
  assert_eq(stdout, "1\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "stream-object-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "{a:(1,error(\"late\"))}",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "error: late\n")
  assert_eq(stdout, "{\"a\":1}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "stream-nested-map-catch" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2]"),
    "[try (.[] | if . == 2 then error(\"late\") else . end) catch .]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[1,\"late\"]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-path-function-first" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"a\":1,\"b\":2}"),
    "def f: .a,.b; path(first(f))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[\"a\"]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-recursive-first" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("1"),
    "def forever: .,forever; first(forever)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "1\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-limit-catch-control" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "limit(1;try (1,2) catch 3)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "1\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-first-optional-control" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "first((1,2)?)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "1\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-empty-limit" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "[limit(5;empty)]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-operator-cartesian" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "[(1,2)+(10,20)]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[11,12,21,22]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-operator-right-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "(1,2)+(10,error(\"late\"))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "error: late\n")
  assert_eq(stdout, "11\n12\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "stream-nested-first-limit" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "[limit(2;(first((1,2)),3,4))]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[1,3]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "stream-try-downstream-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "try 1 catch \"caught\" | error(\"outside\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "error: outside\n")
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "stream-optional-downstream-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "(1,2)? | if . == 2 then error(\"outside\") else . end",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "error: outside\n")
  assert_eq(stdout, "1\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "stream-nested-try" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "try ((try 1 catch \"inner\") | error(\"outside\")) catch .",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "outside\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-dynamic-split" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"text\":\"a:b,c\",\"separator\":\":\"}"),
    ".separator as $sep | .text | split($sep)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[\"a\",\"b,c\"]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-split-stream" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a:b,c\""),
    "split((\":\",\",\"))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[\"a\",\"b,c\"]\n[\"a:b\",\"c\"]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-split-empty" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"a😀b\""),
    "split(\"\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[\"a\",\"😀\",\"b\"]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-dynamic-join" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[\"a\",null,1,true]"),
    "\"|\" as $sep | join($sep)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "a||1|true\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-join-container-error" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[\"a\",{}]"),
    "join(\",\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "cannot add: string (\"a,\") and object ({})\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "builtin-prefix-dynamic" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"abcdef\""),
    "startswith((\"ab\",\"bc\")),endswith((\"ef\",\"de\"))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "true\nfalse\ntrue\nfalse\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-trim-dynamic" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"abcd\""),
    "(\"ab\",\"cd\") as $part | ltrimstr($part),rtrimstr($part)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "cd\nabcd\nabcd\nab\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-string-type-errors" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "(try split(\",\") catch .),(try startswith(\"a\") catch .),(try join(\",\") catch .)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "split cannot be applied to: null\nstartswith(\"a\") cannot be applied to: null\njoin(\",\") cannot be applied to: null\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-argument-type-errors" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"abc\""),
    "(try split(1) catch .),(try startswith(1) catch .),(try endswith(null) catch .)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "split cannot be applied to: number (1)\nstartswith(1) cannot be applied to: string (\"abc\")\nendswith(null) cannot be applied to: string (\"abc\")\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-contains-deep" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse(
      "{\"a\":[{\"x\":\"foobar\",\"y\":3},{\"x\":\"other\"}],\"b\":2}",
    ),
    "contains({a:[{x:\"foo\"}]}),contains({a:[{x:\"bar\"}]}),contains({a:[{x:\"no\"}]})",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "true\ntrue\nfalse\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-contains-array" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2,3]"),
    "contains([1,3]),contains([3,1]),contains([1,1]),contains([])",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "true\ntrue\ntrue\ntrue\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-contains-stream" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"abc\""),
    "contains((\"a\",\"z\")),contains(empty)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "true\nfalse\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-contains-mismatch" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2]"),
    "(try contains(1) catch .),(try contains(null) catch .)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "contains(1) cannot be applied to: array ([1,2])\ncontains(null) cannot be applied to: array ([1,2])\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-inside-deep" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"x\":\"foo\"}"),
    "inside({x:\"foobar\",y:1}),inside({x:\"no\"})",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "true\nfalse\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-has-dynamic" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"a\":null,\"b\":2}"),
    "(\"a\",\"c\") as $key | has($key)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "true\nfalse\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-has-array" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[1,2]"),
    "has((-1,0,1,2,0.5)),(try has(\"0\") catch .)",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "false\ntrue\ntrue\nfalse\ntrue\nhas(\"0\") cannot be applied to: array ([1,2])\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-has-null" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("null"),
    "has((\"x\",0,true,null))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "false\nfalse\nfalse\nfalse\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-in-stream" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"x\""),
    "in(({x:1},{y:2},null))",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "true\nfalse\nfalse\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-type-selectors" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[null,false,0,\"\",[],{}]"),
    "[.[]|scalars],[.[]|arrays],[.[]|objects],[.[]|booleans],[.[]|numbers],[.[]|strings],[.[]|nulls],[.[]|iterables]",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(
    stdout, "[null,false,0,\"\"]\n[[]]\n[{}]\n[false]\n[0]\n[\"\"]\n[null]\n[[],{}]\n",
  )
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-keys-unsorted" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"z\":1,\"a\":2}"),
    "keys_unsorted",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "function not defined: keys_unsorted/0\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "builtin-from-entries-aliases" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse(
      "[{\"Key\":\"a\",\"Value\":1},{\"name\":\"b\",\"value\":2},{\"Name\":\"c\",\"Value\":3},{\"key\":\"d\"}]",
    ),
    "from_entries",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{\"a\":1,\"b\":2,\"c\":3,\"d\":null}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-from-entries-invalid" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("[{\"key\":1,\"value\":\"a\"}]"),
    "from_entries",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "expected a string for object key but got: number (1)\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "builtin-json-string-key-order" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"z\":1,\"abc\":2}"),
    "tojson,tostring",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{\"abc\":2,\"z\":1}\n{\"abc\":2,\"z\":1}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-json-string-escapes" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("{\"x\":\"<>&  \"}"),
    "tojson",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "{\"x\":\"<>&  \"}\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "builtin-split-regex" {
  let (stdout, error) = @formatter_jq.render(
    @json.parse("\"A1b22C\""),
    "split(\"[0-9]+\";\"i\")",
    environment={ "LANG": "C", "TZ": "UTC" },
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[\"A\",\"b\",\"C\"]\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}
