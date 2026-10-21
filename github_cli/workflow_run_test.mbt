///|
test "workflow JSON inputs retain string types and reject non-string values" {
  assert_true(
    @github_cli.workflow_json_inputs({
      "null": Json::null(),
      "unicode": "你好",
    })
    is Ok({ "null": String(""), "unicode": String("你好"), .. }),
  )
  assert_true(@github_cli.workflow_json_inputs(Json::null()) is Ok(Null))
  for value in [Json(1), Json(true), Json::array([]), Json::object({})] {
    assert_true(@github_cli.workflow_json_inputs({ "input": value }) is Err(_))
  }
}

///|
test "workflow run keeps all input occurrences and rejects mixed stdin sources" {
  guard @github_cli.parse([
      "workflow", "run", "ci.yml", "-fkey=one", "--raw-field=key=two", "-F", "key=magic",
      "--ref=topic",
    ])
    is @github_cli.Business(options) else {
    fail("options")
  }
  guard @github_cli.parse_workflow_run(options) is Ok(parsed) else {
    fail("parse")
  }
  assert_eq(parsed.raw_fields, ["key=one", "key=two"])
  assert_eq(parsed.file_fields, ["key=magic"])
  assert_eq(parsed.ref_name, "topic")
  guard @github_cli.parse([
      "workflow", "run", "ci.yml", "--json", "-f", "key=value",
    ])
    is @github_cli.Business(options) else {
    fail("options")
  }
  assert_true(@github_cli.parse_workflow_run(options) is Err(_))
}
