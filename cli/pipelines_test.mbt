///|
async test "pipeline controls retain accepted versus applied outcomes and describe pending execution" {
  let sent : Array[@gh.Request] = []
  let transport = @gh.Transport::new(origin="https://moonhub.example", send=request => {
    @async.pause()
    sent.push(request)
    assert_true(request.verb is @gh.Post)
    assert_eq(request.body, Some("{}"))
    assert_true(request.headers.contains(("If-Match", "\"observed-run\"")))
    match request.path {
      "/api/v1/repos/team/demo/pipelines/42/cancel" =>
        @gh.Response::new(
          status=202,
          body="{\"version\":1,\"data\":{\"number\":\"42\",\"kind\":\"cancel_requested\"}}",
        )
      "/api/v1/repos/team/demo/pipelines/41/rerun" => {
        let envelope : Json = {
          "version": 1,
          "data": {
            "number": "43",
            "workflow_path": ".github/workflows/build.yml",
            "workflow_name": "Build\n\u001b[31mred",
            "source_branch": "main",
            "commit_sha": "0123456789abcdef0123456789abcdef01234567",
            "state": "queued",
            "conclusion": Json::null(),
            "created_at": "2026-10-09 00:00:00",
          },
        }
        @gh.Response::new(status=201, body=envelope.stringify(), headers=[
          ("ETag", "\"new-run\""),
        ])
      }
      _ => fail("unexpected pipeline request or implicit preflight")
    }
  })
  guard @moonhub.Client::new(
      config=@moonhub.ClientConfig::new(base_url="https://moonhub.example"),
      transport~,
    )
    is Ok(client) else {
    fail("client creation failed")
  }
  for json in [true, false] {
    for (action, number) in [("cancel", "42"), ("rerun", "41")] {
      let args = ["pipeline", action, number, "--if-match", "\"observed-run\""] +
        (if json { ["--json"] } else { [] })
      guard @cli.parse(
          args,
          host_env="https://moonhub.example",
          repo_env="team/demo",
        )
        is Ok(@cli.Run(options)) else {
        fail("pipeline command rejected")
      }
      let before = sent.length()
      let output = @cli.run(options, client, operation_id="pipeline-command")
      assert_eq(sent.length(), before + 1)
      assert_eq(output.exit_code, 0)
      assert_eq(output.stderr, "")
      if json {
        let envelope = @json.parse(output.stdout)
        if action == "cancel" {
          assert_true(
            envelope
            is {
              "version": 1,
              "outcome": "accepted",
              "etag": Null,
              "data": { "number": "42", "kind": "cancel_requested", .. },
              ..
            },
          )
        } else {
          assert_true(
            envelope
            is {
              "version": 1,
              "outcome": "applied",
              "etag": "\"new-run\"",
              "data": {
                "number": "43",
                "state": "queued",
                "conclusion": Null,
                ..
              },
              ..
            },
          )
        }
      } else {
        assert_true(
          output.stdout.contains("inspect pipeline view for completion"),
        )
        if action == "cancel" {
          assert_true(output.stdout.contains("#42\tcancellation requested"))
          assert_false(output.stdout.contains("cancelled"))
        } else {
          assert_true(output.stdout.contains("#43\tqueued\t-\tBuild  [31mred"))
          assert_true(
            output.stdout.contains("New run created from the original snapshot"),
          )
          assert_false(output.stdout.contains("\u001b"))
          assert_false(output.stdout.contains("success"))
        }
      }
    }
  }
  assert_eq(sent.length(), 4)
}
