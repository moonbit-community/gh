///|
/// Preserve numeric spellings for schema checks and generic API passthrough.
/// Keep core's existing depth limit and last-member-wins object policy.
pub fn parse(source : StringView) -> Json raise {
  @moonjson.loads(source, { ..@moonjson.strict, depth: 1024, })
}
