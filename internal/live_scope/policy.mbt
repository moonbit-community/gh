///|
pub struct Policy {
  priv permits : Array[Permit]
  priv ledger : Ledger?
}

///|
pub fn Policy::from_json(value : Json) -> Policy raise ScopeError {
  guard value is { "schema": Number(1, ..), "permits": Array(values), .. } &&
    values.length() <= 128 else {
    raise InvalidLedger
  }
  if values.is_empty() {
    return { permits: [], ledger: None, }
  }
  guard value is { "ledger": ledger, .. } else { raise InvalidLedger }
  let ledger = Ledger::from_json(ledger)
  {
    permits: values.map(value => permit_from_json(value, ledger)),
    ledger: Some(ledger),
  }
}

///|
/// Reject mutation/subscription documents even if a query appears first.
/// The conservative scan may reject literal text containing these words; it
/// must never interpret a GraphQL POST as read-only based on HTTP method.
fn readonly_graphql(body : Bytes?) -> Bool {
  let source = match body {
    Some(bytes) => @utf8.decode(bytes) catch { _ => return false }
    None => return false
  }
  let value = @json.parse(source) catch { _ => return false }
  guard value is { "query": String(query), .. } else { return false }
  let query = query.trim().to_owned()
  (
    query.has_prefix("query ") ||
    query.has_prefix("query(") ||
    query.has_prefix("query{") ||
    query.has_prefix("{")
  ) &&
  !query.contains("mutation") &&
  !query.contains("subscription")
}

///|
pub fn Policy::allows(
  self : Policy,
  origin : String,
  verb : String,
  path : String,
  body : Bytes?,
  now_ms~ : Int64 = 0L,
  credential_sha256? : String,
) -> Bool {
  if verb is ("GET" | "HEAD" | "OPTIONS") {
    // GraphQL is normally POST; don't allow mutation documents via GET.
    return path.split_once("?").map_or(path, pair => pair.0.to_owned()) !=
      "/graphql"
  }
  if origin == "https://api.github.com" &&
    verb == "POST" &&
    path == "/graphql" &&
    readonly_graphql(body) {
    return true
  }
  guard self.ledger is Some(ledger) else { return false }
  if ledger.credential_sha256 is Some(expected) &&
    credential_sha256 != Some(expected) {
    return false
  }
  self.permits.any(permit => {
    permit.allows(origin, verb, path, body) &&
    permit.validated_for(ledger, body, now_ms)
  })
}
