///|
/// Help covers only commands implemented by the current increment.
pub fn help_text() -> String {
  command_spec().render_help() +
  "\n" +
  (
    #|Read commands:
    #|  meta
    #|  auth status
    #|  repo list
    #|  repo view [OWNER/NAME]
    #|  issue list | issue view NUMBER
    #|  pr list    | pr view NUMBER
    #|  pipeline list | pipeline view NUMBER
    #|
    #|Generic JSON API (one attempt, including GET):
    #|  api /PATH [-X GET|POST|PUT|PATCH|DELETE] [-H 'Name: value'] [--input FILE|-]
    #|PATH is relative to /api/v1; query strings are sent unchanged.
    #|The default method is GET. Input requires an explicit non-GET method.
    #|Input is UTF-8 JSON, at most 80000 bytes; the original text is sent unchanged.
    #|Headers may be repeated with -H. Credentials and transport headers are reserved.
    #|API returns the entire JSON response; it does not paginate or unwrap data.
    #|If supplied, --max-attempts must be 1 for api. No repository inference is used.
    #|
    #|Write commands (no prompts or automatic retries):
    #|  issue create --title TEXT [--body TEXT | --body-file PATH]
    #|  issue comment NUMBER (--body TEXT | --body-file PATH)
    #|  issue close NUMBER --if-match TAG
    #|  issue reopen NUMBER --if-match TAG
    #|  pr create --title TEXT --source BRANCH --target BRANCH [--draft]
    #|            [--body TEXT | --body-file PATH]
    #|  pr comment NUMBER (--body TEXT | --body-file PATH) --if-match TAG
    #|  pr merge NUMBER --if-match TAG
    #|  pipeline cancel NUMBER --if-match TAG
    #|  pipeline rerun NUMBER --if-match TAG
    #|Use --body-file - for UTF-8 stdin. Body text is limited to 20000 code units.
    #|TAG is the quoted strong ETag from view --json, not a wildcard or weak tag.
    #|Merge success reports acceptance; inspect pr view for eventual completion.
    #|Pipeline cancel reports a request; rerun creates a new run of the original snapshot.
    #|
    #|Offline traces (no host or credentials required):
    #|  trace list --trace PATH
    #|  trace show OPERATION_ID --trace PATH
    #|  Filters: --operation-id ID --request-id ID --status N --method GET
    #|           --path-prefix /api/v1/... --limit N
    #|Defaults: most recent 100 matches in file order; --limit accepts 1..1000.
    #|
    #|List flags: --page N --per-page N --paginate --max-pages N
    #|Defaults: page 1, per-page 30, at most 20 pages when paginating.
    #|Read retry: --max-attempts 1..5 (default 3 per page); 1 disables retries.
    #|Retries cover transport failures and HTTP 429/502/503/504; writes run once.
    #|Credentials: MOONHUB_TOKEN or --config PATH. Tokens are not accepted in argv.
    #|Example: gh issue list --host https://moonhub.example -R team/demo --json
    #|Requires MoonHub's /api/v1 contract; browser sessions are not used.
  ) +
  "\n"
}

///|
pub fn version() -> String {
  "0.1.0"
}
