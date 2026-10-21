///|
async fn execute_issue_develop(
  parsed : ParsedBusiness,
  repo : @github_cli.RepositoryContext,
  client : @github.Client,
) -> @github_cli.Output {
  let issue = match collaboration_subject(parsed, repo, client, "id number") {
    Ok(issue) => issue
    Err(error) => return error
  }
  guard issue is { "id": String(issue_id), "number": Number(number, ..), .. } else {
    return @github_cli.failure(message="invalid issue response")
  }
  let variables = collaboration_variables(repo)
  variables["number"] = Json::number(number)
  let linked = match
    collaboration_graphql(
      client, "issue.develop", "query ListLinkedBranches($owner:String!,$name:String!,$number:Int!) { repository(owner:$owner,name:$name) { issue(number:$number) { linkedBranches(first:30) { nodes { ref { name repository { url } } } } } } }",
      variables,
    ) {
    Ok(data) => data
    Err(error) => return error
  }
  guard graphql_object_path(linked, [
      "repository", "issue", "linkedBranches", "nodes",
    ])
    is Some(Array(branches)) else {
    return @github_cli.failure(message="invalid linked branches response")
  }
  if parsed_flag(parsed, "list") {
    if branches.is_empty() {
      // Upstream's NoResultsError is silent on a pipe and exits successfully.
      return @github_cli.success(stdout="")
    }
    let output = StringBuilder()
    for branch in branches {
      guard branch
        is {
          "ref": {
            "name": String(name),
            "repository": { "url": String(url), .. },
            ..
          },
          ..
        } else {
        return @github_cli.failure(message="invalid linked branch")
      }
      output.write_string(name + "\t" + url + "/tree/" + name + "\n")
    }
    return @github_cli.success(stdout=output.to_string())
  }
  let branch_repo = match parsed.values.get("branch_repo") {
    None => repo
    Some(name) =>
      match @github_cli.RepositoryContext::parse(name) {
        Ok(value) if value.host() == repo.host() => value
        _ =>
          return @github_cli.failure(
            message="branch repository must use the same host",
          )
      }
  }
  let branch_name = parsed.values.get("name").unwrap_or("")
  let variables = collaboration_variables(branch_repo)
  let base = parsed.values.get("base").unwrap_or("")
  variables["ref"] = Json::string(base)
  let data = match
    collaboration_graphql(
      client, "issue.develop", "query FindRepoBranchID($owner:String!,$name:String!,$ref:String!) { repository(owner:$owner,name:$name) { id defaultBranchRef { target { oid } } ref(qualifiedName:$ref) { target { oid } } } }",
      variables,
    ) {
    Ok(data) => data
    Err(error) => return error
  }
  guard graphql_object_path(data, ["repository", "id"]) is Some(String(repo_id)) else {
    return @github_cli.failure(message="branch repository was not found")
  }
  let oid = match
    graphql_object_path(data, [
      "repository",
      if base.is_empty() {
        "defaultBranchRef"
      } else {
        "ref"
      },
      "target",
      "oid",
    ]) {
    Some(String(oid)) => oid
    _ => return @github_cli.failure(message="could not find base branch")
  }
  let url = "https://" + branch_repo.host() + "/" + branch_repo.full_name()
  if !branch_name.is_empty() {
    for branch in branches {
      if branch
        is {
          "ref": {
            "name": String(name),
            "repository": { "url": String(existing_url), .. },
            ..
          },
          ..
        } &&
        name == branch_name &&
        existing_url == url {
        return collaboration_develop_result(branch_repo, name, base)
      }
    }
  }
  let input : Map[String, Json] = {
    "issueId": Json::string(issue_id),
    "repositoryId": Json::string(repo_id),
    "oid": Json::string(oid),
  }
  if !branch_name.is_empty() {
    input["name"] = Json::string(branch_name)
  }
  let data = match
    collaboration_graphql(
      client,
      "issue.develop",
      "mutation CreateLinkedBranch($input:CreateLinkedBranchInput!) { createLinkedBranch(input:$input) { linkedBranch { ref { name } } } }",
      { "input": Json::object(input) },
    ) {
    Ok(data) => data
    Err(error) => return error
  }
  match
    graphql_object_path(data, [
      "createLinkedBranch", "linkedBranch", "ref", "name",
    ]) {
    Some(String(name)) if !name.is_empty() =>
      collaboration_develop_result(branch_repo, name, base)
    _ => @github_cli.failure(message="linked branch creation was not confirmed")
  }
}

///|
async fn collaboration_develop_result(
  repo : @github_cli.RepositoryContext,
  name : String,
  base : String,
) -> @github_cli.Output {
  if !base.is_empty() {
    match
      run_native_process("git", [
        "config",
        "--local",
        "branch." + name + ".gh-merge-base",
        base,
      ]) {
      Ok(result) if result.exit_code() == 0 => ()
      Ok(result) => {
        let error = @utf8.decode(result.stderr()) catch {
          _ => "could not save branch configuration\n"
        }
        return @github_cli.Output::new(
          stderr="failed to run git: " + error + "\n",
          exit_code=1,
        )
      }
      Err(_) =>
        return @github_cli.failure(
          message="could not save branch configuration",
        )
    }
  }
  @github_cli.success(
    stdout=repo.host() + "/" + repo.full_name() + "/tree/" + name + "\n",
  )
}
