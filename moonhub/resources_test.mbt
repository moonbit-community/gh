///|
test "resource JSON preserves nullable fields and decimal IDs without precision loss" {
  let user : @moonhub.User = @json.from_json({
    "id": "9007199254740993",
    "name_key": "alice",
    "display_name": "Alice 月",
    "is_site_admin": false,
    "future_field": "ignored",
  })
  assert_eq(user.id, "9007199254740993")
  assert_eq(
    user.to_json().stringify(),
    "{\"id\":\"9007199254740993\",\"name_key\":\"alice\",\"display_name\":\"Alice 月\",\"is_site_admin\":false}",
  )
  let repository : @moonhub.Repository = @json.from_json({
    "owner": "team",
    "name": "demo",
    "visibility": "private",
    "default_branch": null,
  })
  assert_eq(repository.default_branch, None)
  assert_eq(repository.ssh_url, None)
  assert_eq(
    repository.to_json().stringify(),
    "{\"owner\":\"team\",\"name\":\"demo\",\"visibility\":\"private\",\"default_branch\":null,\"ssh_url\":null}",
  )
  let issue : @moonhub.Issue = @json.from_json({
    "number": 7,
    "title": "Fix read API",
    "description": "A body",
    "status": "open",
    "author": "alice",
    "edit_version": "9007199254740993",
    "assignee": null,
  })
  assert_eq(issue.assignee, None)
  assert_eq(issue.edit_version, Some("9007199254740993"))
  assert_true(
    issue.to_json()
    is {
      "author": "alice",
      "assignee": Null,
      "edit_version": "9007199254740993",
      "updated_at": Null,
      ..
    },
  )
  let mr : @moonhub.MergeRequest = @json.from_json({
    "number": 2,
    "title": "Read operations",
    "description": "",
    "source": "feature/read",
    "target": "main",
    "draft": true,
    "status": "open",
    "version": "0",
    "edit_version": "1",
    "merged_sha": null,
  })
  assert_eq(mr.version, Some("0"))
  assert_true(
    mr.to_json()
    is { "draft": true, "merged_sha": Null, "job_status": Null, .. },
  )
  let meta : @moonhub.Meta = @json.from_json({
    "api_version": 1,
    "server_version": "0.1.0",
    "capabilities": ["issues", "future_capability"],
  })
  assert_eq(meta.capabilities.length(), 2)
  assert_true(meta.to_json() is { "api_version": 1, .. })
}

///|
fn[T] rejected_resource(
  decode : (Json) -> T raise @json.JsonDecodeError,
  value : Json,
) -> Bool {
  try {
    let _ = decode(value)
    false
  } catch {
    _ => true
  }
}

///|
test "resource decoders reject shape drift and lossy numeric representations" {
  let issue : (Json) -> @moonhub.Issue raise @json.JsonDecodeError = value => {
    @json.from_json(value)
  }
  let user : (Json) -> @moonhub.User raise @json.JsonDecodeError = value => {
    @json.from_json(value)
  }
  let mr : (Json) -> @moonhub.MergeRequest raise @json.JsonDecodeError = value => {
    @json.from_json(value)
  }
  let repository : (Json) -> @moonhub.Repository raise @json.JsonDecodeError = value => {
    @json.from_json(value)
  }
  let meta : (Json) -> @moonhub.Meta raise @json.JsonDecodeError = value => {
    @json.from_json(value)
  }
  let numbers : Array[Json] = [0, -1, 1.5, 2147483648, "1", null]
  for number in numbers {
    assert_true(
      rejected_resource(issue, {
        "number": number,
        "title": "x",
        "description": "",
        "status": "open",
      }),
    )
  }
  let ids : Array[Json] = ["0", "01", "-1", "1.0", "", 1, null]
  for id in ids {
    assert_true(
      rejected_resource(user, {
        "id": id,
        "name_key": "alice",
        "display_name": "Alice",
        "is_site_admin": false,
      }),
    )
  }
  let optional_values : Array[Json] = [1, [], ["alice"], true, {}]
  for optional in optional_values {
    assert_true(
      rejected_resource(issue, {
        "number": 1,
        "title": "x",
        "description": "",
        "status": "open",
        "assignee": optional,
      }),
    )
  }
  let versions : Array[Json] = ["01", "-1", "1e2", 1]
  for version in versions {
    assert_true(
      rejected_resource(issue, {
        "number": 1,
        "title": "x",
        "description": "",
        "status": "open",
        "edit_version": version,
      }),
    )
  }
  assert_true(
    rejected_resource(issue, { "number": 1, "title": "x", "status": "open" }),
  )
  assert_true(
    rejected_resource(issue, {
      "number": 1,
      "title": "x",
      "description": "",
      "status": "merged",
    }),
  )
  assert_true(
    rejected_resource(mr, {
      "number": 1,
      "title": "x",
      "description": "",
      "source": "feature",
      "target": "main",
      "draft": "false",
      "status": "open",
    }),
  )
  assert_true(
    rejected_resource(mr, {
      "number": 1,
      "title": "x",
      "description": "",
      "source": "feature",
      "target": "main",
      "draft": false,
      "status": "open",
      "job_status": "future",
    }),
  )
  assert_true(
    rejected_resource(repository, {
      "owner": "team",
      "name": "demo",
      "visibility": "internal",
    }),
  )
  assert_true(
    rejected_resource(meta, {
      "api_version": 1.5,
      "server_version": "0.1",
      "capabilities": [],
    }),
  )
  assert_true(
    rejected_resource(meta, {
      "api_version": 2,
      "server_version": "0.1",
      "capabilities": [],
    }),
  )
  assert_true(
    rejected_resource(meta, {
      "api_version": 1,
      "server_version": "0.1",
      "capabilities": [1],
    }),
  )
}

///|
test "repository references follow MoonHub namespace rules before URL construction" {
  guard @moonhub.RepositoryRef::parse("team-a/Demo.repo.git") is Ok(repo) else {
    fail("valid repository rejected")
  }
  assert_eq(repo.owner, "team-a")
  assert_eq(repo.name, "Demo.repo.git")
  assert_true(repo.api_path() is Ok("/repos/team-a/Demo.repo.git"))
  for
    value in [
      "https://host/team/demo", "team/demo/extra", "team/../demo", "team/%2e%2e",
      "assets/demo", "-/demo", "Team/demo", "team/-", "team/.git", "team/a?b", "team/a#b",
      "team/a b", "team/a\\b", "/team/demo", "team/demo/", " team/demo",
    ] {
    assert_true(@moonhub.RepositoryRef::parse(value) is Err(_))
  }
  assert_true(
    @moonhub.RepositoryRef::new(owner="team", name="../outside").api_path()
    is Err(_),
  )
}
