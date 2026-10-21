///|
fn validate_commands(
  commands : Array[Command],
  funcs : Map[String, FuncFn],
  variables : Array[String],
) -> Unit raise TemplateError {
  for command in commands {
    if command.fn_ is Some(name) && !funcs.contains(name) {
      raise ParseError("function \"" + name + "\" not defined")
    }
    for argument in command.args {
      match argument {
        Sub(commands) => validate_commands(commands, funcs, variables)
        Var(name, _) if name != "" && !variables.contains(name) =>
          raise ParseError("undefined variable \"$" + name + "\"")
        _ => ()
      }
    }
  }
}

///|
fn validate_nodes(
  nodes : Array[Node],
  funcs : Map[String, FuncFn],
  variables~ : Array[String] = [],
  in_range~ : Bool = false,
) -> Unit raise TemplateError {
  for node in nodes {
    match node {
      Located(line, _, _, node) =>
        validate_nodes([node], funcs, variables~, in_range~) catch {
          ParseError(message) => raise LocatedParse(line, message)
          error => raise error
        }
      Scope(nodes) =>
        validate_nodes(nodes, funcs, variables=variables.copy(), in_range~)
      Control(stop) =>
        if !in_range {
          raise ParseError(
            "{{" +
            (if stop { "break" } else { "continue" }) +
            "}} outside {{range}}",
          )
        }
      Text(_) => ()
      Action(commands) => validate_commands(commands, funcs, variables)
      Assign(name, declaration, commands) => {
        validate_commands(commands, funcs, variables)
        if declaration {
          variables.push(name)
        }
      }
      IfNode(commands, yes, no) | WithNode(commands, yes, no) => {
        validate_commands(commands, funcs, variables)
        validate_nodes(yes, funcs, variables=variables.copy(), in_range~)
        validate_nodes(no, funcs, variables=variables.copy(), in_range~)
      }
      RangeNode(commands, key, value, declaration, yes, no) => {
        validate_commands(commands, funcs, variables)
        let child = variables.copy()
        if declaration {
          for name in [key, value] {
            if name is Some(name) {
              child.push(name)
            }
          }
        }
        validate_nodes(yes, funcs, variables=child.copy(), in_range=true)
        validate_nodes(no, funcs, variables=child.copy(), in_range~)
      }
      Invoke(_, Some(commands)) => validate_commands(commands, funcs, variables)
      Invoke(_, None) => ()
    }
  }
}
