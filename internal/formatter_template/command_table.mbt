///|
/// Command tables share the formatter's Unicode width allocation and truncation.
/// Styles are applied after measuring and padding, so ANSI bytes use no width.
pub fn command_table(
  rows : Array[Array[String]],
  width : Int32,
  color~ : Bool = false,
  column_styles~ : Array[String] = [],
) -> String {
  let widths : Array[Int32] = []
  for row in rows {
    for index, cell in row {
      if index >= widths.length() {
        widths.push(0)
      }
      widths[index] = widths[index].max(@unicodewidth.str_width(cell))
    }
  }
  let widths = table_column_widths(widths, width)
  let output = StringBuilder()
  for row_index, row in rows {
    for index, cell in row {
      if index > 0 {
        output.write_string("  ")
      }
      let cell = match (cell.find("\n"), cell.find("\r")) {
        (Some(a), Some(b)) => cell[:a.min(b)].to_owned() + "..."
        (Some(a), None) | (None, Some(a)) => cell[:a].to_owned() + "..."
        _ => cell
      }
      let cell = truncate_display(cell, widths[index])
      let cell = cell +
        (if index < row.length() - 1 {
          " ".repeat((widths[index] - @unicodewidth.str_width(cell)).max(0))
        } else {
          ""
        })
      let style = if row_index == 0 {
        "0;4;39"
      } else {
        column_styles.get(index).unwrap_or("")
      }
      output.write_string(
        if color && !style.is_empty() {
          "\u001b[" + style + "m" + cell + "\u001b[0m"
        } else {
          cell
        },
      )
    }
    output.write_char('\n')
  }
  output.to_string()
}
