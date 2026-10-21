///|
pub fn actions_success_icon(context : FormatContext) -> String {
  watch_style("✓", "32", context)
}

///|
pub fn actions_failure_icon(context : FormatContext) -> String {
  watch_style("X", "31", context)
}

///|
pub fn render_cache_deleted(
  count : Int32,
  repository : String,
  context : FormatContext,
) -> String {
  if !context.terminal {
    return ""
  }
  actions_success_icon(context) +
  " Deleted " +
  count.to_string() +
  (if count == 1 { " cache" } else { " caches" }) +
  " from " +
  repository +
  "\n"
}

///|
pub fn render_rerun_requested(
  run_id : String,
  job_id : String,
  only_failed : Bool,
  debug_logging : Bool,
  context : FormatContext,
) -> String {
  if !context.terminal {
    return ""
  }
  actions_success_icon(context) +
  " Requested rerun " +
  (if job_id.is_empty() {
    (if only_failed { "(failed jobs) " } else { "" }) +
    "of run " +
    watch_style(run_id, "36", context)
  } else {
    "of job " +
    watch_style(job_id, "36", context) +
    " on run " +
    watch_style(run_id, "36", context)
  }) +
  (if debug_logging { " with debug logging enabled" } else { "" }) +
  "\n"
}
