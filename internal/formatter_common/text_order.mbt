///|
/// Go compares UTF-8 strings lexicographically; for valid JSON strings this is
/// Unicode scalar order, not MoonBit's default shortlex or UTF-16 order.
pub fn compare_text(left : String, right : String) -> Int32 {
  let a = left.iter()
  let b = right.iter()
  while true {
    match (a.next(), b.next()) {
      (None, None) => return 0
      (None, Some(_)) => return -1
      (Some(_), None) => return 1
      (Some(x), Some(y)) => if x != y { return x.compare(y) }
    }
  }
  0
}
