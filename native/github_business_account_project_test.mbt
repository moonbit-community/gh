///|
async test "account project create resolves current owner and creates Projects V2" {
  let (output, seen, traces) = account_fixture(
    [
      "project", "create", "--owner", "@me", "--title", "123", "--format", "json",
    ],
    [
      account_fixture_response({ "node_id": "U_fixture", "type": "User" }),
      account_fixture_response({
        "data": {
          "createProjectV2": {
            "projectV2": {
              "id": "P_fixture",
              "number": 1,
              "title": "123",
              "url": "https://github.com/users/acme/projects/1",
            },
          },
        },
      }),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen.length(), 2)
  assert_eq(seen[0].path(), "/user")
  assert_eq(seen[1].path(), "/graphql")
  guard account_fixture_body(seen[1]) is Object(body) else {
    fail("GraphQL body missing")
  }
  assert_eq(
    body.get("variables"),
    Some({ "input": { "ownerId": "U_fixture", "title": "123" } }),
  )
  assert_true(output.stdout().contains("P_fixture"))
  for trace in traces {
    assert_false(trace.contains("account-fixture-token"))
    assert_false(trace.contains("U_fixture"))
  }
}

///|
async test "account project update close reopen and delete resolve numeric project first" {
  let owner = account_fixture_response({
    "node_id": "O_fixture",
    "type": "Organization",
  })
  let project : Json = {
    "id": "P_fixture",
    "number": 7,
    "title": "title",
    "url": "https://github.com/orgs/acme/projects/7",
  }
  let lookup = account_fixture_response({
    "data": { "node": { "projectV2": project } },
  })
  let cases : Array[(String, Array[String], Json)] = [
    (
      "edit",
      [
        "--title", "false", "-d", "details", "--readme", "readme", "--visibility",
        "PRIVATE",
      ],
      {
        "projectId": "P_fixture",
        "title": "false",
        "shortDescription": "details",
        "readme": "readme",
        "public": false,
      },
    ),
    ("close", [], { "projectId": "P_fixture", "closed": true }),
    ("close", ["--undo"], { "projectId": "P_fixture", "closed": false }),
    ("delete", [], { "projectId": "P_fixture" }),
  ]
  for (command, flags, expected) in cases {
    let args = ["project", command, "7", "--owner", "acme"]
    args.append(flags)
    let mutation = if command == "delete" {
      account_fixture_response({
        "data": { "deleteProjectV2": { "deletedProjectV2Id": "P_fixture" } },
      })
    } else {
      account_fixture_response({
        "data": { "updateProjectV2": { "projectV2": project } },
      })
    }
    let (output, seen, _) = account_fixture(args, [owner, lookup, mutation])
    assert_eq(output.exit_code(), 0)
    assert_eq(output.stdout(), "")
    assert_eq(seen[0].path(), "/users/acme")
    guard account_fixture_body(seen[1]) is Object(lookup_body) else {
      fail("lookup body missing")
    }
    assert_eq(
      lookup_body.get("variables"),
      Some({ "owner": "O_fixture", "number": 7 }),
    )
    assert_true(
      lookup_body.get("query").unwrap().stringify().contains("on Organization"),
    )
    guard account_fixture_body(seen[2]) is Object(mutation_body) else {
      fail("mutation body missing")
    }
    assert_eq(mutation_body.get("variables"), Some({ "input": expected }))
  }
}

///|
async test "account project list follows cursor and keeps errors before mutation" {
  let owner = account_fixture_response({
    "node_id": "U_fixture",
    "type": "User",
  })
  let (output, seen, _) = account_fixture(
    ["project", "list", "--owner", "@me", "--limit", "2", "--format", "json"],
    [
      owner,
      account_fixture_response({
        "data": {
          "node": {
            "projectsV2": {
              "nodes": [{ "id": "P_one" }],
              "pageInfo": { "hasNextPage": true, "endCursor": "cursor-one" },
            },
          },
        },
      }),
      account_fixture_response({
        "data": {
          "node": {
            "projectsV2": {
              "nodes": [{ "id": "P_two" }],
              "pageInfo": { "hasNextPage": false, "endCursor": "cursor-two" },
            },
          },
        },
      }),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen.length(), 3)
  guard account_fixture_body(seen[2]) is Object(fields) else {
    fail("page body missing")
  }
  assert_eq(
    fields.get("variables"),
    Some({ "owner": "U_fixture", "first": 1, "after": "cursor-one" }),
  )
  assert_eq(@json.parse(output.stdout()), {
    "projects": [{ "id": "P_one" }, { "id": "P_two" }],
    "totalCount": 2,
  })
  let failures : Array[Json] = [
    {
      "errors": [{ "message": "insufficient project scope" }],
      "data": Json::null(),
    },
    { "data": { "node": { "projectV2": Json::null() } } },
    { "data": { "node": { "projectV2": {} } } },
  ]
  for payload in failures {
    let (failed, seen, _) = account_fixture(["project", "delete", "7"], [
      owner,
      account_fixture_response(payload),
    ])
    assert_true(failed.exit_code() != 0)
    assert_eq(seen.length(), 2)
  }
}

///|
async test "account status aggregates all work categories with org and repeated excludes" {
  let graphql = account_fixture_response({
    "data": {
      "assignments": {
        "nodes": [
          {
            "__typename": "Issue",
            "title": "kept issue",
            "number": 1,
            "updatedAt": "2026-01-01T00:00:00Z",
            "repository": { "nameWithOwner": "acme/keep" },
          },
          {
            "__typename": "PullRequest",
            "title": "kept pull",
            "number": 2,
            "updatedAt": "2026-01-02T00:00:00Z",
            "repository": { "nameWithOwner": "acme/keep" },
          },
        ],
      },
      "reviewRequested": {
        "nodes": [
          {
            "__typename": "PullRequest",
            "title": "kept review",
            "number": 3,
            "updatedAt": "2026-01-03T00:00:00Z",
            "repository": { "nameWithOwner": "acme/keep" },
          },
        ],
      },
    },
  })
  let viewer = account_fixture_response({ "login": "fixture-user" })
  let notifications = account_fixture_response([
    {
      "reason": "mention",
      "repository": { "full_name": "acme/keep" },
      "subject": {
        "latest_comment_url": "https://api.github.example/repos/acme/keep/issues/comments/9",
      },
    },
    {
      "reason": "mention",
      "repository": { "full_name": "acme/skip" },
      "subject": {
        "latest_comment_url": "https://api.github.example/repos/acme/skip/issues/comments/8",
      },
    },
    {
      "reason": "assign",
      "repository": { "full_name": "acme/keep" },
      "subject": {
        "latest_comment_url": "https://api.github.example/repos/acme/keep/issues/comments/7",
      },
    },
  ])
  let comment = account_fixture_response({ "body": "hello @fixture-user" })
  let events = account_fixture_response([
    {
      "type": "IssuesEvent",
      "repo": { "name": "acme/keep" },
      "payload": { "action": "opened", "issue": { "title": "kept activity" } },
    },
    {
      "type": "IssuesEvent",
      "repo": { "name": "acme/skip" },
      "payload": {
        "action": "opened",
        "issue": { "title": "excluded activity" },
      },
    },
    {
      "type": "PullRequestEvent",
      "repo": { "name": "other/repo" },
      "payload": {
        "action": "opened",
        "pull_request": { "title": "outside organization" },
      },
    },
  ])
  let (output, seen, _) = account_fixture(
    ["status", "-o", "acme", "-e", "acme/skip", "--exclude", "acme/another"],
    [graphql, viewer, notifications, comment, events],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen.length(), 5)
  assert_eq(seen[0].path(), "/graphql")
  assert_eq(seen[1].path(), "/user")
  assert_eq(seen[2].path(), "/notifications")
  assert_eq(seen[3].path(), "/repos/acme/keep/issues/comments/9")
  assert_eq(seen[4].path(), "/users/fixture-user/received_events")
  guard account_fixture_body(seen[0]) is Object(graphql_body) else {
    fail("GraphQL body missing")
  }
  guard graphql_body.get("variables") is Some(Object(variables)) else {
    fail("GraphQL variables missing")
  }
  for key in ["assigns", "reviews"] {
    guard variables.get(key) is Some(String(expression)) else {
      fail("GraphQL search variable missing")
    }
    assert_true(expression.contains("org:acme"))
    assert_true(expression.contains("-repo:acme/skip"))
    assert_true(expression.contains("-repo:acme/another"))
  }
  for
    heading in [
      "Assigned Issues", "Assigned Pull Requests", "Review Requests", "Mentions",
      "Repository Activity",
    ] {
    assert_true(output.stdout().contains(heading))
  }
  assert_true(output.stdout().contains("kept issue"))
  assert_true(output.stdout().contains("kept pull"))
  assert_true(output.stdout().contains("kept review"))
  assert_true(output.stdout().contains("hello @fixture-user"))
  assert_true(output.stdout().contains("kept activity"))
  assert_false(output.stdout().contains("excluded activity"))
  assert_false(output.stdout().contains("outside organization"))
}

///|
async test "account HTTP permission errors remain failures without followup writes" {
  for
    args in [
      ["ssh-key", "list"],
      ["project", "delete", "7"],
      ["gist", "edit", "abc123", "--desc", "new"],
      ["status"],
    ] {
    let (output, seen, _) = account_fixture(args, [
      @github.RawResponse::new(
        status=403,
        body=b"{\"message\":\"Resource not accessible\"}",
      ),
    ])
    assert_true(output.exit_code() != 0)
    assert_true(output.stderr().contains("Resource not accessible"))
    assert_eq(seen.length(), 1)
  }
}
