///|
test "run log scanner preserves invalid UTF8 and makes controls visible with line prefixes" {
  assert_eq(
    @github_cli.render_run_log("job", Some("step"), b"a\r\n\nb\x1b\x00\x7f\xff"),
    b"job\tstep\ta\njob\tstep\t\njob\tstep\tb^[^@^?\xff\n",
  )
  assert_eq(@github_cli.render_run_log("job", None, b""), b"")
  assert_eq(
    @github_cli.render_run_log("job", None, b"tail\n"),
    b"job\tUNKNOWN STEP\ttail\n",
  )
}
