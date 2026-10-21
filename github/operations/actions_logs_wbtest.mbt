///|
test "step logs take precedence and failed selection uses job and step conclusions" {
  let jobs : Array[WorkflowJob] = [
    {
      id: "1",
      run_id: "2",
      name: "test / linux:",
      status: "completed",
      conclusion: "failure",
      started_at: "",
      completed_at: "",
      steps: [
        { name: "last", number: 3, status: "completed", conclusion: "failure", },
        {
          name: "first",
          number: 1,
          status: "completed",
          conclusion: "success",
        },
        {
          name: "missing",
          number: 2,
          status: "completed",
          conclusion: "failure",
        },
      ],
    },
  ]
  let paths = [
    "0_test  linux.txt", "test  linux/3_last.txt", "test  linux/1_first.txt",
  ]
  guard plan_run_logs(jobs, paths) is Ok(all) else { fail("plan") }
  assert_eq(all.map(segment => segment.step_name), [Some("first"), Some("last")])
  guard plan_run_logs(jobs, paths, only_failed=true) is Ok(failed) else {
    fail("failed plan")
  }
  assert_eq(failed.map(segment => segment.archive_path), [
    Some("test  linux/3_last.txt"),
  ])
}

///|
test "job logs prefer regular ordinals and cap API fallback before downloading" {
  let job : WorkflowJob = {
    id: "1",
    run_id: "2",
    name: "build",
    status: "completed",
    conclusion: "failure",
    started_at: "",
    completed_at: "",
    steps: [],
  }
  guard plan_run_logs([job], ["-99_build.txt", "12_build.txt"]) is Ok(segments) else {
    fail("plan")
  }
  assert_eq(segments[0].archive_path, Some("12_build.txt"))
  assert_eq(segments[0].step_name, None)
  assert_true(plan_run_logs(Array::make(25, job), []) is Ok(_))
  assert_true(plan_run_logs(Array::make(26, job), []) is Err(_))
  let prefix = String::make(89, 'a')
  assert_eq(archive_job_name(prefix + "😀x"), prefix + "\uFFFD")
}
