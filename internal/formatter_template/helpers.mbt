///|
fn is_ws(value : UInt16) -> Bool {
  value is (' ' | '\t' | '\r' | '\n')
}

///|
fn trim(value : String) -> String {
  trim_right_ws(trim_left_ws(value))
}

///|
fn starts_with(value : String, prefix : String) -> Bool {
  value.has_prefix(prefix)
}
