///|
/// The pinned core parser still implements the depth limit, although its
/// optional parameter is deprecated without a replacement. Keep the small
/// limit for untrusted proof metadata and isolate that compatibility detail.
#warnings("-deprecated")
pub fn parse(text : StringView) -> Json raise @json.ParseError {
  @json.parse(text, max_nesting_depth=64)
}
