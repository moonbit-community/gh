///|
fn truncate_display(value : String, max_width : Int32) -> String {
  if @unicodewidth.str_width(value) <= max_width {
    return value
  }
  let tail = if max_width >= 5 { "..." } else { "" }
  let available = (max_width - tail.length()).max(0)
  let result = StringBuilder()
  let mut used = 0
  for ch in value {
    let size = @unicodewidth.char_width(ch).unwrap_or(0)
    if used + size > available {
      break
    }
    result.write_char(ch)
    used += size
  }
  result.write_string(tail)
  if used + tail.length() < max_width {
    result.write_char(' ')
  }
  result.to_string()
}

///|
/// Follow go-gh v2.16.1's allocation order: short columns, equal shares for
/// flexible columns, then remaining space from left to right.
fn table_column_widths(
  maximum : Array[Int32],
  viewport : Int32,
) -> Array[Int32] {
  let count = maximum.length()
  if count == 0 {
    return []
  }
  let widths = Array::make(count, 0)
  let mut available = viewport - (count - 1) * 2
  if available > 0 {
    let share = available / count
    for index, value in maximum {
      if value < share {
        widths[index] = value
        available -= value
      }
    }
  }
  let flexible = widths.iter().filter(value => value == 0).count()
  if flexible > 0 {
    let share = available / flexible
    for index, value in maximum {
      if widths[index] == 0 {
        widths[index] = value.min(share.max(0))
        available -= widths[index]
      }
    }
  }
  if available > 0 {
    for index, value in maximum {
      let extra = (value - widths[index]).min(available)
      widths[index] += extra
      available -= extra
      if available <= 0 {
        break
      }
    }
  }
  widths
}
