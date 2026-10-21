///|
pub fn render_workflow_state(
  name : String,
  enabled : Bool,
  context : FormatContext,
) -> String {
  if !context.terminal ||
    context.environment
    .get("GH_PROMPT_DISABLED")
    .map_or(false, value => !value.is_empty()) {
    return ""
  }
  watch_style("✓", if enabled { "32" } else { "31" }, context) +
  (if enabled { " Enabled " } else { " Disabled " }) +
  watch_style(name, "1", context) +
  "\n"
}

///|
pub fn render_workflows(
  workflows : Array[@operations.Workflow],
  options : WorkflowManageOptions,
  context : FormatContext,
) -> Output {
  let workflows = workflows.filter(workflow => {
    options.all || workflow.state == "active"
  })
  if workflows.is_empty() {
    return success(
      stdout="",
      stderr=if context.terminal { "no workflows found\n" } else { "" },
    )
  }
  if options.fields is Some(fields) {
    let items = workflows.map(workflow => {
      let values : Map[String, Json] = Map([])
      for field in fields {
        values[field] = match field {
          "id" => @json.parse(workflow.id) catch { _ => Json::null() }
          "name" => Json(workflow.name)
          "path" => Json(workflow.path)
          "state" => Json(workflow.state)
          _ => Json::null()
        }
      }
      Json::object(values)
    })
    return render_response(
      200,
      [],
      @utf8.encode(Json::array(items).stringify() + "\n"),
      jq?=options.jq,
      template?=if options.jq.map_or(false, value => !value.is_empty()) {
        None
      } else {
        options.template
      },
      format_context=context,
    )
  }
  let rows = workflows.map(workflow => {
    [workflow.name, workflow.state, workflow.id]
  })
  if !context.terminal {
    return success(stdout=rows.map(row => row.join("\t") + "\n").join(""))
  }
  success(
    stdout=@formatter_template.command_table(
      [["NAME", "STATE", "ID"]] + rows,
      context.width,
      color=context.color,
      column_styles=["", "", "0;36"],
    ),
  )
}
