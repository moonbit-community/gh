///|
pub struct RunLogSegment {
  job_id : String
  job_name : String
  step_name : String?
  archive_path : String?
}

///|
pub fn workflow_failed(conclusion : String) -> Bool {
  conclusion
  is ("action_required" | "failure" | "startup_failure" | "timed_out")
}

///|
/// Matching follows the fixed gh run/view logs contract: API job names lose
/// '/' and ':', are truncated at 90 UTF-16 units, then have surrounding space
/// trimmed. Numeric job-log prefixes are ordinals, never assumed to be IDs.
fn archive_job_name(name : String) -> String {
  let clean = name.replace_all(old="/", new="").replace_all(old=":", new="")
  let text = StringBuilder()
  let mut units = 0
  for ch in clean {
    let width = if ch.to_int() > 65535 { 2 } else { 1 }
    if units + width > 90 {
      if units < 90 {
        text.write_char('\uFFFD')
      }
      break
    }
    text.write_char(ch)
    units += width
  }
  text.to_string().trim().to_owned()
}

///|
pub fn plan_run_logs(
  jobs : Array[WorkflowJob],
  paths : Array[String],
  only_failed~ : Bool = false,
) -> Result[Array[RunLogSegment], String] {
  let output : Array[RunLogSegment] = []
  let mut missing = 0
  for job in jobs {
    if job.conclusion == "skipped" ||
      (only_failed && !workflow_failed(job.conclusion)) {
      continue
    }
    let name = archive_job_name(job.name)
    let steps : Map[Int32, String] = Map([])
    let mut full : String? = None
    let mut legacy : String? = None
    for path in paths {
      if path.strip_prefix(name + "/") is Some(file) &&
        !file.contains("/") &&
        file.has_suffix(".txt") &&
        file.split_once("_") is Some((number, _)) {
        for step in job.steps {
          if number == step.number.to_string() && !steps.contains(step.number) {
            steps[step.number] = path
          }
        }
      }
      if path.strip_suffix("_" + name + ".txt") is Some(prefix) {
        if numeric_id(prefix.to_owned()) && full is None {
          full = Some(path)
        } else if prefix.strip_prefix("-") is Some(number) &&
          numeric_id(number.to_owned()) &&
          legacy is None {
          legacy = Some(path)
        }
      }
    }
    if !steps.is_empty() {
      let ordered = job.steps.copy()
      ordered.sort_by((a, b) => a.number.compare(b.number))
      for step in ordered {
        if only_failed && !workflow_failed(step.conclusion) {
          continue
        }
        if steps.get(step.number) is Some(path) {
          output.push({
            job_id: job.id,
            job_name: job.name,
            step_name: Some(step.name),
            archive_path: Some(path),
          })
        }
      }
    } else {
      let path = match full {
        Some(_) => full
        None => legacy
      }
      if path is None {
        missing += 1
      }
      guard missing <= 25 else {
        return Err(
          "too many API requests needed to fetch logs; try narrowing down to a specific job with the `--job` option",
        )
      }
      output.push({
        job_id: job.id,
        job_name: job.name,
        step_name: None,
        archive_path: path,
      })
    }
  }
  Ok(output)
}
