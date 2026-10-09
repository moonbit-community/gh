///|
fn pipeline_group() -> @argparse.Command {
  command("pipeline", about="Inspect and control MoonHub pipeline runs", subcommands=[
    list_command(),
    command("view", positionals=[number_argument()]),
    command("cancel", options=[if_match_option()], positionals=[
      number_argument(),
    ]),
    command("rerun", options=[if_match_option()], positionals=[
      number_argument(),
    ]),
  ])
}

///|
fn pipeline_command(
  action : String,
  leaf : @argparse.Matches,
  repo : @moonhub.RepositoryRef,
) -> Result[ReadCommand, String] {
  guard value(leaf, "number") is Some(raw_number) else {
    return Err("pipeline requires a canonical positive decimal run number")
  }
  let number = match @moonhub.parse_pipeline_number(raw_number) {
    Ok(number) => number
    Err(_) =>
      return Err(
        "pipeline requires a canonical positive signed 64-bit decimal run number",
      )
  }
  if action == "view" {
    return Ok(Pipeline(repo, number))
  }
  guard value(leaf, "if-match") is Some(raw_tag) else {
    return Err(
      "pipeline control requires --if-match with the strong ETag from view",
    )
  }
  let tag = match @moonhub.EntityTag::parse(raw_tag) {
    Ok(tag) => tag
    Err(_) => return Err("--if-match must be one strong ETag")
  }
  match action {
    "cancel" => Ok(CancelPipeline(repo, number, tag))
    "rerun" => Ok(RerunPipeline(repo, number, tag))
    _ => Err("unsupported pipeline command")
  }
}

///|
fn pipeline_line(run : @moonhub.Pipeline) -> String {
  "#\{run.number}\t\{run.state}\t\{run.conclusion.unwrap_or("-")}\t\{safe_text(run.workflow_name)}"
}
