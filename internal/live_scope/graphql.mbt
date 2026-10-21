///|
fn compact_graphql(query : String) -> String {
  let result = StringBuilder()
  for ch in query.iter() {
    if !(ch is (' ' | '\n' | '\t' | '\r')) {
      result.write_char(ch)
    }
  }
  result.to_string()
}

///|
/// Closed operation documents prevent aliases, extra mutations, inline foreign
/// IDs, and unreviewed input fields from bypassing resource ownership checks.
fn Ledger::validate_graphql(
  self : Ledger,
  key : String,
  body : Bytes?,
) -> Unit raise ScopeError {
  guard key != "fixture" else { raise OutsideScope }
  let resource = self.owned(key)
  guard resource.node_id is Some(node_id) && body is Some(bytes) else {
    raise OutsideScope
  }
  let value = @json.parse(@utf8.decode(bytes) catch { _ => raise OutsideScope }) catch {
    _ => raise OutsideScope
  }
  guard value is Object(envelope) &&
    envelope
    .keys()
    .all(name => name is ("query" | "operationName" | "variables")) &&
    envelope.get("query") is Some(String(query)) &&
    envelope.get("variables") is Some(Object(variables)) else {
    raise OutsideScope
  }
  let query = compact_graphql(query)
  let (operation, input_key, wrapped) = match (resource.kind, query) {
    (
      "issue",
      "mutationIssueDelete($issueId:ID!){deleteIssue(input:{issueId:$issueId}){clientMutationId}}",
    ) => ("IssueDelete", "issueId", false)
    (
      "issue",
      "mutationIssuePin($input:PinIssueInput!){pinIssue(input:$input){issue{id}}}",
    ) => ("IssuePin", "issueId", true)
    (
      "issue",
      "mutationIssueUnpin($input:UnpinIssueInput!){unpinIssue(input:$input){issue{id}}}",
    ) => ("IssueUnpin", "issueId", true)
    (
      "project",
      "mutationAccountProjectDelete($input:DeleteProjectV2Input!){deleteProjectV2(input:$input){deletedProjectV2Id}}",
    ) => ("AccountProjectDelete", "projectId", true)
    _ => raise OutsideScope
  }
  guard envelope
    .get("operationName")
    .map_or(true, value => value == Json(operation)) else {
    raise OutsideScope
  }
  let input = if wrapped {
    guard variables.length() == 1 &&
      variables.get("input") is Some(Object(input)) else {
      raise OutsideScope
    }
    input
  } else {
    variables
  }
  guard input.length() == 1 && input.get(input_key) == Some(Json(node_id)) else {
    raise OutsideScope
  }
}

///|
pub fn Ledger::approve_graphql_mutation(
  self : Ledger,
  key : String,
  observed_id : String,
  body : Bytes,
) -> Permit raise ScopeError {
  let resource = self.owned(key)
  guard resource.remote_id == Some(observed_id) else { raise OutsideScope }
  self.validate_graphql(key, Some(body))
  {
    verb: "POST",
    origin: "https://api.github.com",
    path: "/graphql",
    body_sha256: digest(Some(body)),
    resource_key: key,
    creation: false,
    inventory: None,
  }
}
