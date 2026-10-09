///|
/// Preserve numeric spellings for schema checks and generic API passthrough.
/// Bound recursion for the default Windows Native stack as well as POSIX.
/// Keep strict syntax and the last-member-wins object policy.
pub fn parse(source : StringView) -> Json raise {
  @moonjson.loads(source, { ..@moonjson.strict, depth: 128, })
}
