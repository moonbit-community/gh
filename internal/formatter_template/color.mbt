///|
/// ANSI style syntax used by gh's mgutz/ansi formatter.
fn color_style(value : String, style : String) -> String {
  if style.is_empty() {
    return value
  }
  if style == "off" {
    return value + "\u001b[0m"
  }
  if style == "reset" {
    return "\u001b[0m" + value + "\u001b[0m"
  }
  let pair = style.split(":").collect()
  let foreground = pair[0].split("+").collect()
  let modifiers = foreground.get(1).unwrap_or("")
  let codes = ["0"]
  for
    (modifier, code) in [
      ("b", "1"),
      ("d", "2"),
      ("B", "5"),
      ("u", "4"),
      ("i", "7"),
      ("s", "9"),
    ] {
    if modifiers.contains(modifier) {
      codes.push(code)
    }
  }
  codes.push(
    color_component(foreground[0].to_owned(), modifiers.contains("h"), false),
  )
  if pair.get(1) is Some(background) && !background.is_empty() {
    let background = background.split("+").collect()
    codes.push(
      color_component(
        background[0].to_owned(),
        background.get(1).map_or(false, value => value.contains("h")),
        true,
      ),
    )
  }
  "\u001b[" + codes.join(";") + "m" + value + "\u001b[0m"
}

///|
fn color_component(name : String, high : Bool, background : Bool) -> String {
  let number = Some(@string.parse_int(name)) catch { _ => None }
  if number is Some(value) {
    return (if background { "48;5;" } else { "38;5;" }) + value.to_string()
  }
  let index = match name {
    "red" => 1
    "green" => 2
    "yellow" => 3
    "blue" => 4
    "magenta" => 5
    "cyan" => 6
    "white" => 7
    "default" => 9
    _ => 0
  }
  (index + (if background { 40 } else { 30 }) + (if high { 60 } else { 0 })).to_string()
}
