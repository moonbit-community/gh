///|
/// Go's diagnostics display the parsed command, independent of source spacing.
/// Source offsets are retained separately on commands for accurate locations.
fn command_text(command : Command) -> String {
  let parts : Array[String] = []
  if command.fn_ is Some(name) {
    parts.push(name)
  }
  for argument in command.args {
    parts.push(argument_text(argument))
  }
  parts.join(" ")
}

///|
fn argument_text(argument : Arg) -> String {
  match argument {
    Dot => "."
    Field(path) => "." + path.join(".")
    Var(name, path) =>
      "$" + name + (if path.is_empty() { "" } else { "." + path.join(".") })
    StrLit(value) => Json(value).stringify()
    IntLit(value) => value.to_string()
    FloatLit(value) => value.to_string()
    BoolLit(value) => if value { "true" } else { "false" }
    NilLit => "nil"
    Sub(commands) => "(" + commands.map(command_text).join(" | ") + ")"
  }
}
