///|
/// Run one command. The injected client owns transport, credentials,
/// and tracing; this package owns deterministic output and exit policy.
/// File and stdin bodies must be read by the caller and supplied as body.
pub async fn run(
  opts : RunOptions,
  client : @moonhub.Client,
  operation_id~ : String,
  body? : String,
) -> Output {
  if opts.command is Api(verb, path, headers) {
    return run_api(opts, client, verb, path, headers, operation_id~, body?)
  }
  let body = match (opts.body_input, body) {
    (Some(Literal(text)), _) => text
    (Some(File(_) | Stdin), Some(text)) => text
    (Some(File(_) | Stdin), None) =>
      return failure_output(
        @gh.ApiFailure::new(
          kind=@gh.InvalidRequest(message="body input was not resolved"),
        ),
        json=opts.json,
        outcome=@moonhub.NotSent,
      )
    (None, _) => ""
  }
  match opts.command {
    Api(_, _, _) => abort("api command was dispatched above")
    Meta =>
      render_read(
        client.meta(operation_id~),
        opts.json,
        meta => meta.to_json(),
        meta => {
          "MoonHub \{safe_text(meta.server_version)} (API \{meta.api_version})"
        },
      )
    CurrentUser =>
      render_read(
        client.current_user(operation_id~),
        opts.json,
        user => user.to_json(),
        user => "\{safe_text(user.name_key)}\t\{safe_text(user.display_name)}",
      )
    Repository(repo) =>
      render_read(
        client.repository(repo, operation_id~),
        opts.json,
        repo => repo.to_json(),
        repository_line,
      )
    Repositories =>
      render_read(
        client.repositories(
          page=opts.page,
          per_page=opts.per_page,
          paginate=opts.paginate,
          max_pages=opts.max_pages,
          operation_id~,
        ),
        opts.json,
        repos => Json::array(repos.map(repo => repo.to_json())),
        repos => lines(repos.map(repository_line)),
        list=true,
      )
    Issues(repo) =>
      render_read(
        client.issues(
          repo,
          page=opts.page,
          per_page=opts.per_page,
          paginate=opts.paginate,
          max_pages=opts.max_pages,
          operation_id~,
        ),
        opts.json,
        issues => Json::array(issues.map(issue => issue.to_json())),
        issues => lines(issues.map(issue_line)),
        list=true,
      )
    Issue(repo, number) =>
      render_read(
        client.issue(repo, number, operation_id~),
        opts.json,
        issue => issue.to_json(),
        issue_line,
      )
    MergeRequests(repo) =>
      render_read(
        client.merge_requests(
          repo,
          page=opts.page,
          per_page=opts.per_page,
          paginate=opts.paginate,
          max_pages=opts.max_pages,
          operation_id~,
        ),
        opts.json,
        requests => Json::array(requests.map(request => request.to_json())),
        requests => lines(requests.map(merge_request_line)),
        list=true,
      )
    MergeRequest(repo, number) =>
      render_read(
        client.merge_request(repo, number, operation_id~),
        opts.json,
        request => request.to_json(),
        merge_request_line,
      )
    Pipelines(repo) =>
      render_read(
        client.pipelines(
          repo,
          page=opts.page,
          per_page=opts.per_page,
          paginate=opts.paginate,
          max_pages=opts.max_pages,
          operation_id~,
        ),
        opts.json,
        runs => Json::array(runs.map(run => run.to_json())),
        runs => lines(runs.map(pipeline_line)),
        list=true,
      )
    Pipeline(repo, number) =>
      render_read(
        client.pipeline(repo, number, operation_id~),
        opts.json,
        run => run.to_json(),
        pipeline_line,
      )
    CancelPipeline(repo, number, tag) =>
      render_mutation(
        client.cancel_pipeline(repo, number, if_match=tag, operation_id~),
        opts.json,
        receipt => receipt.to_json(),
        receipt => {
          "#\{receipt.number}\tcancellation requested; inspect pipeline view for completion"
        },
      )
    RerunPipeline(repo, number, tag) =>
      render_mutation(
        client.rerun_pipeline(repo, number, if_match=tag, operation_id~),
        opts.json,
        run => run.to_json(),
        run => {
          pipeline_line(run) +
          "\nNew run created from the original snapshot; inspect pipeline view for completion."
        },
      )
    CreateIssue(repo, title) =>
      render_mutation(
        client.create_issue(repo, title~, description=body, operation_id~),
        opts.json,
        issue => issue.to_json(),
        issue_line,
      )
    CommentIssue(repo, number) =>
      render_mutation(
        client.comment_issue(repo, number, body~, operation_id~),
        opts.json,
        receipt => receipt.to_json(),
        receipt => "#\{receipt.number}\tcomment added",
      )
    CloseIssue(repo, number, tag) =>
      render_mutation(
        client.close_issue(repo, number, if_match=tag, operation_id~),
        opts.json,
        issue => issue.to_json(),
        issue_line,
      )
    ReopenIssue(repo, number, tag) =>
      render_mutation(
        client.reopen_issue(repo, number, if_match=tag, operation_id~),
        opts.json,
        issue => issue.to_json(),
        issue_line,
      )
    CreateMergeRequest(repo, title, source, target, draft) =>
      render_mutation(
        client.create_merge_request(
          repo,
          title~,
          source~,
          target~,
          draft~,
          description=body,
          operation_id~,
        ),
        opts.json,
        request => request.to_json(),
        merge_request_line,
      )
    CommentMergeRequest(repo, number, tag) =>
      render_mutation(
        client.comment_merge_request(
          repo,
          number,
          body~,
          if_match=tag,
          operation_id~,
        ),
        opts.json,
        receipt => receipt.to_json(),
        receipt => "#\{receipt.number}\tcomment added",
      )
    MergeMergeRequest(repo, number, tag) =>
      render_mutation(
        client.merge_merge_request(repo, number, if_match=tag, operation_id~),
        opts.json,
        receipt => receipt.to_json(),
        receipt => {
          "#\{receipt.number}\tmerge accepted (\{receipt.job_status}); inspect pr view for completion"
        },
      )
  }
}
