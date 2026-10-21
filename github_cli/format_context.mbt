///|
/// Explicit formatting inputs keep output deterministic in controlled tests.
/// Native callers supply the clock and terminal state; SDK callers can inject
/// them without depending on a process environment.
pub struct FormatContext {
  terminal : Bool
  progress_enabled : Bool
  color : Bool
  width : Int32
  now_unix : Int64
  local_zone : @time.Zone?
  environment : Map[String, String]
}

///|
pub fn FormatContext::new(
  terminal~ : Bool = false,
  progress_enabled? : Bool,
  color~ : Bool = false,
  width~ : Int32 = 80,
  now_unix~ : Int64 = 0L,
  local_zone? : @time.Zone,
  environment~ : Map[String, String] = Map([]),
) -> FormatContext {
  {
    terminal,
    progress_enabled: progress_enabled.unwrap_or(terminal),
    color,
    width: width.max(1),
    now_unix,
    local_zone,
    environment: environment.copy(),
  }
}
