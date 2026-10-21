///|
fn parse_rfc3339(
  source : String,
) -> (@time.PlainDateTime, Int32) raise TemplateError {
  match @formatter_common.parse_rfc3339(source) {
    Ok(value) => value
    Err(message) => raise ExecError(message)
  }
}

///|
fn time_ago(input : String, now_unix : Int64) -> String raise TemplateError {
  let (date, offset) = parse_rfc3339(input)
  let elapsed = now_unix - (date.to_unix_second() - offset.to_int64())
  if elapsed < 60L {
    return "just now"
  }
  let (amount, unit) = if elapsed < 3600L {
    (elapsed / 60L, "minute")
  } else if elapsed < 86400L {
    (elapsed / 3600L, "hour")
  } else if elapsed < 2592000L {
    (elapsed / 86400L, "day")
  } else if elapsed < 31536000L {
    (elapsed / 2592000L, "month")
  } else {
    (elapsed / 31536000L, "year")
  }
  amount.to_string() +
  " " +
  unit +
  (if amount == 1L { "" } else { "s" }) +
  " ago"
}

///|
fn padded(value : Int32, length : Int32, space~ : Bool = false) -> String {
  let digits = value.to_string()
  (if space { " " } else { "0" }).repeat((length - digits.length()).max(0)) +
  digits
}

///|
fn time_format(
  layout : String,
  input : String,
  local_zone : @time.Zone?,
) -> String raise TemplateError {
  let (date, offset) = parse_rfc3339(input)
  let months = [
    "January", "February", "March", "April", "May", "June", "July", "August", "September",
    "October", "November", "December",
  ]
  let days = [
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
  ]
  let day_index = ((date.to_plain_date().to_unix_day() + 4L) % 7L + 7L) % 7L
  let weekday = days[day_index.to_int()]
  let month = months[date.month() - 1]
  let zone = (if offset < 0 { "-" } else { "+" }) +
    padded(offset.abs() / 3600, 2)
  let zone_minutes = padded(offset.abs() % 3600 / 60, 2)
  let hour12 = if date.hour() % 12 == 0 { 12 } else { date.hour() % 12 }
  let zone_name = if offset == 0 {
    "UTC"
  } else {
    match local_zone {
      Some(local_zone) => {
        let matched = try {
          let zone_offset = @time.unix(
            date.to_unix_second() - offset.to_int64(),
            zone=local_zone,
          ).offset()
          if zone_offset.seconds() == offset {
            Some(zone_offset.abbreviation())
          } else {
            None
          }
        } catch {
          _ => None
        }
        matched.unwrap_or(zone + zone_minutes)
      }
      None => zone + zone_minutes
    }
  }
  let tokens = [
    ("January", month),
    ("Monday", weekday),
    ("2006", padded(date.year(), 4)),
    ("Z07:00", if offset == 0 { "Z" } else { zone + ":" + zone_minutes }),
    ("Z0700", if offset == 0 { "Z" } else { zone + zone_minutes }),
    ("-07:00", zone + ":" + zone_minutes),
    ("-0700", zone + zone_minutes),
    ("Z07", if offset == 0 { "Z" } else { zone }),
    ("-07", zone),
    ("MST", zone_name),
    ("Jan", month[:3].to_owned()),
    ("Mon", weekday[:3].to_owned()),
    ("PM", if date.hour() >= 12 { "PM" } else { "AM" }),
    ("pm", if date.hour() >= 12 { "pm" } else { "am" }),
    ("__2", padded(date.ordinal(), 3, space=true)),
    ("002", padded(date.ordinal(), 3)),
    ("06", padded(date.year() % 100, 2)),
    ("01", padded(date.month(), 2)),
    ("02", padded(date.day(), 2)),
    ("_2", padded(date.day(), 2, space=true)),
    ("15", padded(date.hour(), 2)),
    ("03", padded(hour12, 2)),
    ("04", padded(date.minute(), 2)),
    ("05", padded(date.second(), 2)),
    ("1", date.month().to_string()),
    ("2", date.day().to_string()),
    ("3", hour12.to_string()),
    ("4", date.minute().to_string()),
    ("5", date.second().to_string()),
  ]
  let output = StringBuilder()
  let mut cursor = 0
  while cursor < layout.length() {
    if layout[cursor] is ('.' | ',') &&
      cursor + 1 < layout.length() &&
      layout[cursor + 1] is ('0' | '9') {
      let marker = layout[cursor + 1]
      let mut end = cursor + 1
      while end < layout.length() && layout[end] == marker {
        end += 1
      }
      let count = (end - cursor - 1).min(9)
      let fraction = padded(date.nanosecond(), 9)[:count].to_owned()
      let fraction = if marker == '9' {
        fraction.trim_end(chars="0").to_owned()
      } else {
        fraction
      }
      if !fraction.is_empty() {
        output.write_char(layout.get_char(cursor).unwrap())
        output.write_string(fraction)
      }
      cursor = end
      continue
    }
    let mut matched = false
    for (token, value) in tokens {
      if layout[cursor:].has_prefix(token) {
        output.write_string(value)
        cursor += token.length()
        matched = true
        break
      }
    }
    if !matched {
      let ch = layout.get_char(cursor).unwrap()
      output.write_char(ch)
      cursor += if ch.to_int() > 0xffff { 2 } else { 1 }
    }
  }
  output.to_string()
}
