///|
async test "terminal progress streams during work and restores the cursor on cancellation" {
  let bytes = StringBuilder()
  let mut work_started = false
  let mut work_finished = false
  let context = @github_cli.FormatContext::new(terminal=true, color=true, environment={
    "GH_SPINNER_DISABLED": "false",
  })
  @async.with_task_group() <| group => {
    let task = group.spawn(() => {
      with_terminal_progress(
        context,
        value => bytes.write_string(@utf8.decode(value)),
        () => {
          work_started = true
          @async.sleep(60000)
          work_finished = true
        },
        wait=_ => @async.pause(),
      )
    })
    while !work_started || !bytes.to_string().contains("⣽") {
      @async.pause()
    }
    assert_true(bytes.to_string().has_prefix("\u001b[?25l\r\u001b[K\r"))
    assert_false(bytes.to_string().contains("\u001b[?25h"))
    task.cancel()
  }
  assert_false(work_finished)
  assert_true(bytes.to_string().has_suffix("\u001b[?25h\r\u001b[K"))
  let stopped = bytes.to_string()
  @async.pause()
  assert_eq(bytes.to_string(), stopped)
}

///|
async test "progress respects independent stderr TTY and textual mode and stops on broken writers" {
  let bytes = StringBuilder()
  let write : async (Bytes) -> Unit = value => {
    bytes.write_string(@utf8.decode(value))
  }
  let result = with_terminal_progress(
    @github_cli.FormatContext::new(terminal=true, progress_enabled=false),
    write,
    () => 7,
  )
  assert_eq(result, 7)
  assert_eq(bytes.to_string(), "")
  let result = with_terminal_progress(
    @github_cli.FormatContext::new(terminal=true, environment={
      "GH_SPINNER_DISABLED": "yes",
    }),
    write,
    () => 9,
  )
  assert_eq(result, 9)
  assert_eq(bytes.to_string(), "Working...\n")
  let mut work_started = false
  try
    with_terminal_progress(
      @github_cli.FormatContext::new(terminal=true, environment={
        "GH_SPINNER_DISABLED": "false",
      }),
      _ => fail("closed pipe"),
      () => work_started = true,
    )
  catch {
    _ => ()
  } noraise {
    _ => fail("closed writer ignored")
  }
  assert_false(work_started)
}

///|
async test "progress restores cursor after request failure" {
  let bytes = StringBuilder()
  async fn failed_request() -> Unit {
    @async.pause()
    raise Failure("request failed")
  }
  try
    with_terminal_progress(
      @github_cli.FormatContext::new(terminal=true, environment={
        "GH_SPINNER_DISABLED": "false",
      }),
      value => bytes.write_string(@utf8.decode(value)),
      failed_request,
    )
  catch {
    Failure(message) => assert_eq(message, "request failed")
    error => raise error
  } noraise {
    _ => fail("request failure swallowed")
  }
  assert_true(bytes.to_string().has_suffix("\u001b[?25h\r\u001b[K"))
}
