// Generated from the pinned oracle corpus by scripts/formatter_tests.mbtx.

///|
test "template-variables" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{\"name\":\"MoonBit\"}"),
    "{{$x := .name}}{{$x}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "MoonBit")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-pipeline" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{\"name\":\"MoonBit\"}"),
    "{{.name | printf \"%s!\"}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "MoonBit!")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-range-vars" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[\"a\",\"b\"]"),
    "{{range $i, $v := .}}{{$i}}={{$v}};{{end}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "0=a;1=b;")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-root" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{\"name\":\"root\",\"items\":[{\"name\":\"a\"}]}"),
    "{{range .items}}{{$.name}}:{{.name}}{{end}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "root:a")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-with" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{\"child\":{\"name\":\"ok\"}}"),
    "{{with .child}}{{.name}}{{else}}missing{{end}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "ok")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-trim" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{}"),
    "a  {{- \"b\" -}}  c",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "abc")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-missing" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{}"),
    "{{.missing}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "<no value>")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-sprig" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{}"),
    "{{contains \"oo\" \"Moon\"}} {{hasPrefix \"Mo\" \"Moon\"}} {{replace \"Moon\" \"Sun\" \"MoonBit\"}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "true true SunBit")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-define" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{\"name\":\"Moon\"}"),
    "{{define \"name\"}}Hello {{.name}}{{end}}{{template \"name\" .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "Hello Moon")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-error" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{}"),
    "x{{range .}}",
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "template: :1: unexpected EOF\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "template-table" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[{\"name\":\"a\",\"n\":1},{\"name\":\"long\",\"n\":2}]"),
    "{{range .}}{{tablerow .name .n}}{{end}}{{tablerender}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "a     1\nlong  2\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-assign-scope" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[1,2]"),
    "{{$x := \"old\"}}{{range .}}{{$x = \"new\"}}{{end}}{{$x}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "new")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-shadow" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("true"),
    "{{$x := \"old\"}}{{if .}}{{$x := \"new\"}}{{$x}}{{end}}{{$x}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "newold")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-short-circuit" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("false"),
    "{{and . (index . 3)}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "false")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-undefined-function" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{}"),
    "prefix {{toJSON}}",
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "template: :1: function \"toJSON\" not defined\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "template-index-number" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{\"a\":[1,2]}"),
    "{{index .a 1}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "2")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-len-utf8" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("\"中文😀\""),
    "{{len .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "10")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-table-flush" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{}"),
    "{{tablerow \"a\" 1}}{{tablerow \"long\" 2}}",
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "template: :1:2: executing \"\" at <tablerow \"a\" 1>: error calling tablerow: failed to write table row: cannot convert type to string: 1\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "template-table-unicode" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{}"),
    "{{tablerow \"中文\" \"a\"}}{{tablerow \"x\" \"b\"}}{{tablerender}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "中文  a\nx     b\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-table-float-null" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[1.005,null,true]"),
    "{{tablerow (index . 0) (index . 1) (index . 2)}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "1.00    true\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-truncate-short" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("\"abcdefgh\""),
    "{{truncate 0 .}}|{{truncate 1 .}}|{{truncate 3 .}}|{{truncate 4 .}}|{{truncate 5 .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "|a|abc|abcd|ab...")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-truncate-wide" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("\"中文测试abc\""),
    "{{truncate 3 .}}|{{truncate 5 .}}|{{truncate 6 .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "中 |中...|中... ")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-truncate-null" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("null"),
    "{{truncate 3 .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-pluck-missing" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[{\"name\":\"a\"},{}]"),
    "{{join \",\" (pluck \"name\" .)}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "a,")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-regex" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("\"Moon123\""),
    "{{regexMatch \"^Moon[0-9]+$\" .}} {{regexMatch \"[\" .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "true false")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-timefmt" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("\"2026-10-21T13:05:06.123456+08:00\""),
    "{{timefmt \"2006-01-02 Mon 15:04:05.000 MST Z07:00\" .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "2026-10-21 Wed 13:05:06.123 +0800 +08:00")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-timefmt-names" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("\"2026-01-02T03:04:05Z\""),
    "{{timefmt \"Monday, January _2, 2006 3:04PM -0700\" .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "Friday, January  2, 2026 3:04AM +0000")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-timeago-future" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("\"2099-01-01T00:00:00Z\""),
    "{{timeago .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "just now")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-comment-delimiter" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{}"),
    "a{{/* }} ignored */}}b",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "ab")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-printf-width" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{\"name\":\"Moon\",\"n\":3.14}"),
    "{{printf \"%8s %.2f\" .name .n}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "    Moon 3.14")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-printf-type" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("3"),
    "{{printf \"%d\" .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "%!d(float64=3)")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-printf-quote" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("\"a\\\"b\\nc\""),
    "{{printf \"%q\" .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "\"a\\\"b\\nc\"")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-if-variable" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{\"name\":\"Moon\"}"),
    "{{if $x := .name}}{{$x}}{{else}}empty{{end}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "Moon")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-with-variable" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{\"name\":\"Moon\"}"),
    "{{with $x := .name}}{{$x}}={{.}}{{else}}empty{{end}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "Moon=Moon")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-range-assignment" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[\"a\",\"b\"]"),
    "{{$i := 0}}{{$v := \"\"}}{{range $i, $v = .}}{{$i}}:{{$v}};{{end}}{{$i}}={{$v}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "0:a;1:b;1=b")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-range-empty-binding" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[]"),
    "{{range $i, $v := .}}{{.}}{{else}}{{$i}}:{{$v}}{{end}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[]:[]")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-range-break" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[\"a\",\"b\",\"c\"]"),
    "{{range .}}{{if eq . \"b\"}}{{break}}{{end}}{{.}}{{end}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "a")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-range-continue" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[\"a\",\"b\",\"c\"]"),
    "{{range .}}{{if eq . \"b\"}}{{continue}}{{end}}{{.}}{{end}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "ac")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-undefined-variable" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{}"),
    "prefix {{$x}}",
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "template: :1: undefined variable \"$x\"\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "template-scope-leak" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("true"),
    "{{if .}}{{$x := \"inside\"}}{{end}}{{$x}}",
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "template: :1: undefined variable \"$x\"\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "template-nested-function-error" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[]"),
    "ok {{printf \"%s\" (index . 1)}}",
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "template: :1:18: executing \"\" at <index . 1>: error calling index: index out of range: 1\n",
  )
  assert_eq(stdout, "ok ")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "template-error-line" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[]"),
    "ok\n{{index . 2}}",
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "template: :2:2: executing \"\" at <index . 2>: error calling index: index out of range: 2\n",
  )
  assert_eq(stdout, "ok\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "template-pipe-error" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[]"),
    "ok {{. | index 2}}",
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "template: :1:9: executing \"\" at <index 2>: error calling index: can't index item of type int\n",
  )
  assert_eq(stdout, "ok ")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "template-table-multiline" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[\"a\\nb\",\"c\\rd\"]"),
    "{{range .}}{{tablerow .}}{{end}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "a.\nc.\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-print-spacing" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{}"),
    "{{print 1 2 \"a\" 3 4}}|{{println 1 2 \"a\" 3 4}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "1 2a3 4|1 2 a 3 4\n")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-printf-index" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{}"),
    "{{printf \"%[2]s/%[1]s\" \"a\" \"b\"}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "b/a")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-printf-star" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("1.23456"),
    "{{printf \"%*.*f\" 8 2 .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "    1.23")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-slice" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[1,2,3,4]"),
    "{{slice . 1 3}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "[2 3]")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-urlquery" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("\"中 a&b\""),
    "{{urlquery .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "%E4%B8%AD+a%26b")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-html" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("\"<a href=\\\"x\\\">'&</a>\""),
    "{{html .}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "&lt;a href=&#34;x&#34;&gt;&#39;&amp;&lt;/a&gt;")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}

///|
test "template-join-literal-error" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("[1]"),
    "{{join \",\" .}}|{{color \"red\" 1}}",
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "template: :1:17: executing \"\" at <color \"red\" 1>: error calling color: cannot convert type to string: 1\n",
  )
  assert_eq(stdout, "1|")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "template-parse-line" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{}"),
    "ok\n{{unknown}}",
  )
  assert_eq(
    error.map_or("", message => message + "\n"),
    "template: :2: function \"unknown\" not defined\n",
  )
  assert_eq(stdout, "")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 1)
}

///|
test "template-key-order-unicode" {
  let (stdout, error) = @formatter_template.format(
    @json.parse("{\"z\":1,\"abc\":2,\"😀\":3,\"\":4}"),
    "{{range $key,$value := .}}{{$key}}={{$value}};{{end}}",
  )
  assert_eq(error.map_or("", message => message + "\n"), "")
  assert_eq(stdout, "abc=2;z=1;=4;😀=3;")
  assert_eq(if error is Some(_) { 1 } else { 0 }, 0)
}
