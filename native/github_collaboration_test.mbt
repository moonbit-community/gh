///|
async test "issue pin and unpin resolve node IDs and preserve mutation stderr" {
  for
    (sub, pinned, field, message) in [
      ("pin", false, "pinIssue", "✓ Pinned issue acme/widgets#7 (marker)\n"),
      (
        "unpin", true, "unpinIssue", "✓ Unpinned issue acme/widgets#7 (marker)\n",
      ),
    ] {
    let (output, seen, traces) = account_fixture(
      ["issue", sub, "7", "-R", "acme/widgets"],
      [
        account_fixture_response({
          "data": {
            "repository": {
              "issue": {
                "id": "I_7",
                "number": 7,
                "title": "marker",
                "isPinned": Json::boolean(pinned),
              },
            },
          },
        }),
        account_fixture_response(
          Json::object({
            "data": Json::object(Map([(field, { "issue": { "id": "I_7" } })])),
          }),
        ),
      ],
    )
    assert_eq(output.exit_code(), 0)
    assert_eq(output.stdout(), "")
    assert_eq(output.stderr(), message)
    assert_eq(seen.length(), 2)
    assert_true(
      seen.all(request => {
        request.path() == "/graphql" && request.verb() == "POST"
      }),
    )
    assert_true(
      account_fixture_body(seen[1])
      is { "variables": { "input": { "issueId": String("I_7"), .. }, .. }, .. },
    )
    assert_true(
      traces.all(trace => {
        !trace.contains("account-fixture-token") && !trace.contains("I_7")
      }),
    )
  }
}

///|
async test "already pinned and GraphQL mutation errors are not false successes" {
  let (output, seen, _) = account_fixture(
    ["issue", "pin", "7", "-R", "acme/widgets"],
    [
      account_fixture_response({
        "data": {
          "repository": {
            "issue": {
              "id": "I_7",
              "number": 7,
              "title": "marker",
              "isPinned": true,
            },
          },
        },
      }),
    ],
  )
  assert_eq(seen.length(), 1)
  assert_eq(
    output.stderr(),
    "! Issue acme/widgets#7 (marker) is already pinned\n",
  )
  let (failed, _, _) = account_fixture(
    ["issue", "pin", "7", "-R", "acme/widgets"],
    [
      account_fixture_response({
        "data": {
          "repository": {
            "issue": {
              "id": "I_7",
              "number": 7,
              "title": "marker",
              "isPinned": false,
            },
          },
        },
      }),
      account_fixture_response({
        "errors": [{ "message": "pin limit reached" }],
      }),
    ],
  )
  assert_eq(failed.exit_code(), 1)
  assert_eq(failed.stdout(), "")
  assert_true(failed.stderr().contains("pin limit reached"))
}

///|
async test "revert uses merged PR node and preserves omitted default body" {
  let (output, seen, _) = account_fixture(
    ["pr", "revert", "7", "-R", "acme/widgets", "-t", "123", "-d"],
    [
      account_fixture_response({
        "data": {
          "repository": {
            "pullRequest": {
              "id": "PR_7",
              "number": 7,
              "title": "marker",
              "state": "MERGED",
            },
          },
        },
      }),
      account_fixture_response({
        "data": {
          "revertPullRequest": {
            "revertPullRequest": {
              "url": "https://github.com/acme/widgets/pull/8",
            },
          },
        },
      }),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stdout(), "https://github.com/acme/widgets/pull/8\n")
  assert_true(
    account_fixture_body(seen[1])
    is {
      "variables": {
        "input": {
          "pullRequestId": String("PR_7"),
          "title": String("123"),
          "draft": True,
          "body"? : None,
          ..
        },
        ..
      },
      ..
    },
  )
  let (failed, requests, _) = account_fixture(
    ["pr", "revert", "7", "-R", "acme/widgets"],
    [
      account_fixture_response({
        "data": {
          "repository": {
            "pullRequest": {
              "id": "PR_7",
              "number": 7,
              "title": "marker",
              "state": "OPEN",
            },
          },
        },
      }),
    ],
  )
  assert_eq(failed.exit_code(), 1)
  assert_eq(requests.length(), 1)
}

///|
async test "update branch uses GraphQL rebase and expected head with up-to-date no-op" {
  for behind in [0, 2] {
    let responses = [
      account_fixture_response({
        "data": {
          "repository": {
            "pullRequest": {
              "id": "PR_7",
              "number": 7,
              "title": "marker",
              "state": "OPEN",
              "headRefName": "feature",
              "headRefOid": "abc123",
              "mergeable": "MERGEABLE",
              "headRepositoryOwner": { "login": "fork-owner" },
            },
          },
        },
      }),
      account_fixture_response({
        "data": {
          "repository": {
            "pullRequest": {
              "baseRef": {
                "compare": { "behindBy": Json::number(behind.to_double()) },
              },
            },
          },
        },
      }),
    ]
    if behind > 0 {
      responses.push(
        account_fixture_response({
          "data": {
            "updatePullRequestBranch": { "pullRequest": { "id": "PR_7" } },
          },
        }),
      )
    }
    let (output, seen, _) = account_fixture(
      ["pr", "update-branch", "7", "-R", "acme/widgets", "--rebase"],
      responses,
    )
    assert_eq(output.exit_code(), 0)
    assert_true(
      account_fixture_body(seen[1])
      is { "variables": { "head": String("fork-owner:feature"), .. }, .. },
    )
    if behind > 0 {
      assert_eq(output.stdout(), "✓ PR branch updated\n")
      assert_true(
        account_fixture_body(seen[2])
        is {
          "variables": {
            "input": {
              "pullRequestId": String("PR_7"),
              "expectedHeadOid": String("abc123"),
              "updateMethod": String("REBASE"),
              ..
            },
            ..
          },
          ..
        },
      )
    } else {
      assert_eq(seen.length(), 2)
      assert_eq(output.stdout(), "✓ PR branch already up-to-date\n")
    }
  }
}

///|
async test "deploy key add reads positional file and defaults to read-only" {
  let directory = @fs.tmpdir(prefix="gh-deploy-key-")
  defer @fs.rmdir(directory, recursive=true)
  let path = directory + "/key.pub"
  let key = "ssh-ed25519 AAAAfixture public@test\n"
  @fs.write_file(path, key)
  for writable in [false, true] {
    let args = [
      "repo", "deploy-key", "add", path, "-R", "acme/widgets", "-t", "123",
    ]
    if writable {
      args.push("-w")
    }
    let (output, seen, _) = account_fixture(args, [
      account_fixture_response({ "id": 1 }),
    ])
    assert_eq(output.exit_code(), 0)
    assert_eq(output.stdout(), "")
    assert_eq(seen[0].path(), "/repos/acme/widgets/keys")
    assert_eq(
      account_fixture_body(seen[0]),
      Json::object({
        "title": Json::string("123"),
        "key": Json::string(key),
        "read_only": Json::boolean(!writable),
      }),
    )
  }
}

///|
async test "deploy key permission errors keep API bodies off stdout" {
  let directory = @fs.tmpdir(prefix="gh-deploy-key-denied-")
  defer @fs.rmdir(directory, recursive=true)
  let path = directory + "/key.pub"
  @fs.write_file(path, "ssh-ed25519 AAAAfixture public@test\n")
  let (output, _, _) = account_fixture(
    ["repo", "deploy-key", "add", path, "-R", "acme/widgets"],
    [
      @github.RawResponse::new(
        status=403,
        body=b"{\"message\":\"Resource not accessible by personal access token\",\"status\":\"403\"}",
      ),
    ],
  )
  assert_eq(output.exit_code(), 1)
  assert_eq(output.stdout(), "")
  assert_eq(
    output.stderr(),
    "HTTP 403: Resource not accessible by personal access token (https://api.github.example/repos/acme/widgets/keys)\n",
  )
}

///|
async test "issue status exports independently filtered nonempty collections" {
  let (output, seen, _) = account_fixture(
    ["issue", "status", "-R", "acme/widgets", "--json", "number,title,state"],
    [
      account_fixture_response({
        "data": { "viewer": { "login": "fixture-user" } },
      }),
      account_fixture_response({
        "data": {
          "repository": {
            "hasIssuesEnabled": true,
            "assigned": {
              "nodes": [{ "number": 1, "title": "assigned", "state": "OPEN" }],
            },
            "mentioned": { "nodes": [] },
            "authored": {
              "nodes": [{ "number": 2, "title": "authored", "state": "OPEN" }],
            },
          },
        },
      }),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(@json.parse(output.stdout()), {
    "assigned": [{ "number": 1, "title": "assigned", "state": "OPEN" }],
    "mentioned": [],
    "createdBy": [{ "number": 2, "title": "authored", "state": "OPEN" }],
  })
  assert_true(
    account_fixture_body(seen[1])
    is {
      "variables": { "viewer": String("fixture-user"), .. },
      "query": String(query),
      ..
    } &&
    query.contains("mentioned:$viewer") &&
    query.contains("createdBy:$viewer") &&
    query.contains("assignee:$viewer"),
  )
}

///|
async test "PR status accepts no number and exports account collections" {
  let (output, seen, _) = account_fixture(
    ["pr", "status", "-R", "acme/widgets", "--json", "number,title,state"],
    [
      account_fixture_response({
        "data": {
          "repository": { "pullRequests": { "nodes": [] } },
          "created": {
            "nodes": [{ "number": 7, "title": "mine", "state": "OPEN" }],
          },
          "review": {
            "nodes": [{ "number": 8, "title": "review", "state": "OPEN" }],
          },
        },
      }),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(@json.parse(output.stdout()), {
    "createdBy": [{ "number": 7, "title": "mine", "state": "OPEN" }],
    "needsReview": [{ "number": 8, "title": "review", "state": "OPEN" }],
  })
  assert_true(
    account_fixture_body(seen[0])
    is {
      "variables": { "created": String(created), "review": String(review), .. },
      ..
    } &&
    created.contains("author:@me") &&
    review.contains("review-requested:@me"),
  )
}

///|
async test "status author exports follow the pinned user and bot schema" {
  let (output, _, _) = account_fixture(
    ["issue", "status", "-R", "acme/widgets", "--json", "number,author"],
    [
      account_fixture_response({
        "data": { "viewer": { "login": "fixture-user" } },
      }),
      account_fixture_response({
        "data": {
          "repository": {
            "assigned": { "nodes": [] },
            "mentioned": { "nodes": [] },
            "authored": {
              "nodes": [
                {
                  "number": 1,
                  "author": { "id": "U_1", "login": "person", "name": null },
                },
                { "number": 2, "author": { "login": "automation" } },
              ],
            },
          },
        },
      }),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(@json.parse(output.stdout()), {
    "assigned": [],
    "mentioned": [],
    "createdBy": [
      {
        "number": 1,
        "author": {
          "id": "U_1",
          "login": "person",
          "name": "",
          "is_bot": false,
        },
      },
      { "number": 2, "author": { "login": "app/automation", "is_bot": true } },
    ],
  })
}

///|
fn collaboration_check_response(
  nodes : Array[Json],
  more~ : Bool = false,
  cursor~ : String = "",
) -> @github.RawResponse {
  account_fixture_response({
    "data": {
      "node": {
        "commits": {
          "nodes": [
            {
              "commit": {
                "statusCheckRollup": {
                  "contexts": {
                    "nodes": Json::array(nodes),
                    "pageInfo": {
                      "hasNextPage": Json::boolean(more),
                      "endCursor": Json::string(cursor),
                    },
                  },
                },
              },
            },
          ],
        },
      },
    },
  })
}

///|
async test "PR checks resolves the PR node and merges paginated latest checks and statuses" {
  let (output, seen, _) = account_fixture(
    ["pr", "checks", "7", "-R", "acme/widgets", "--json", "name,state,bucket"],
    [
      account_fixture_response({
        "data": {
          "repository": {
            "pullRequest": {
              "id": "PR_7",
              "number": 7,
              "headRefName": "feature",
            },
          },
        },
      }),
      collaboration_check_response(
        [
          {
            "name": "build",
            "status": "COMPLETED",
            "conclusion": "FAILURE",
            "startedAt": "2026-10-19T00:00:00Z",
          },
        ],
        more=true,
        cursor="next",
      ),
      collaboration_check_response([
        {
          "name": "build",
          "status": "COMPLETED",
          "conclusion": "SUCCESS",
          "startedAt": "2026-10-20T00:00:00Z",
        },
        { "context": "legacy", "state": "PENDING" },
      ]),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(@json.parse(output.stdout()), [
    { "name": "build", "state": "SUCCESS", "bucket": "pass" },
    { "name": "legacy", "state": "PENDING", "bucket": "pending" },
  ])
  assert_true(seen.all(request => request.path() == "/graphql"))
  assert_true(
    account_fixture_body(seen[2])
    is {
      "variables": { "id": String("PR_7"), "after": String("next"), .. },
      ..
    },
  )
}

///|
async test "PR checks reports absent checks and uses pending exit 8 outside JSON" {
  let cases : Array[(Array[Json], Int32)] = [
    ([], 1),
    ([{ "context": "legacy", "state": "PENDING" }], 8),
    ([{ "context": "legacy", "state": "FAILURE" }], 1),
    ([{ "context": "legacy", "state": "SUCCESS" }], 0),
  ]
  for (nodes, expected_code) in cases {
    let (output, _, _) = account_fixture(
      ["pr", "checks", "7", "-R", "acme/widgets"],
      [
        account_fixture_response({
          "data": {
            "repository": {
              "pullRequest": {
                "id": "PR_7",
                "number": 7,
                "headRefName": "feature",
              },
            },
          },
        }),
        collaboration_check_response(nodes),
      ],
    )
    assert_eq(output.exit_code(), expected_code)
    if nodes.is_empty() {
      assert_eq(output.stderr(), "no checks reported on the 'feature' branch\n")
    }
  }
}

///|
async test "issue develop creates a GraphQL linked branch from resolved base oid" {
  let (output, seen, _) = account_fixture(
    ["issue", "develop", "7", "-R", "acme/widgets", "-n", "marker"],
    [
      account_fixture_response({
        "data": { "repository": { "issue": { "id": "I_7", "number": 7 } } },
      }),
      account_fixture_response({
        "data": {
          "repository": { "issue": { "linkedBranches": { "nodes": [] } } },
        },
      }),
      account_fixture_response({
        "data": {
          "repository": {
            "id": "R_1",
            "defaultBranchRef": { "target": { "oid": "abc123" } },
          },
        },
      }),
      account_fixture_response({
        "data": {
          "createLinkedBranch": {
            "linkedBranch": { "ref": { "name": "marker" } },
          },
        },
      }),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(output.stdout(), "github.com/acme/widgets/tree/marker\n")
  assert_true(seen.all(request => request.path() == "/graphql"))
  assert_true(
    account_fixture_body(seen[3])
    is {
      "variables": {
        "input": {
          "issueId": String("I_7"),
          "repositoryId": String("R_1"),
          "oid": String("abc123"),
          "name": String("marker"),
          ..
        },
        ..
      },
      ..
    },
  )
}

///|
async test "issue list excludes PRs before limit and follows an all-PR page" {
  let (output, seen, _) = account_fixture(
    [
      "issue", "list", "-R", "acme/widgets", "--limit", "2", "--json", "number,state",
    ],
    [
      @github.RawResponse::new(
        status=200,
        headers=[
          (
            "Link", "<https://api.github.example/repos/acme/widgets/issues?page=2>; rel=\"next\"",
          ),
        ],
        body=b"[{\"number\":9,\"state\":\"open\",\"pull_request\":{}}]",
      ),
      account_fixture_response([
        { "number": 8, "state": "closed", "pull_request": {} },
        { "number": 7, "state": "open" },
        { "number": 6, "state": "closed" },
        { "number": 5, "state": "open" },
      ]),
    ],
  )
  assert_eq(output.exit_code(), 0)
  assert_eq(seen.length(), 2)
  assert_eq(@json.parse(output.stdout()), [
    { "number": 7, "state": "OPEN" },
    { "number": 6, "state": "CLOSED" },
  ])
}
