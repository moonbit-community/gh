///|
fn auth_copy_yaml(values : Map[String, LocalYaml]) -> Map[String, LocalYaml] {
  let copy : Map[String, LocalYaml] = Map([])
  for key, value in values {
    copy[key] = match value {
      Scalar(value) => Scalar(value)
      Mapping(child) => Mapping(auth_copy_yaml(child))
    }
  }
  copy
}

///|
// Build a fresh config tree so failed transactions do not mutate the caller's
// original account state. This type deliberately has no diagnostic formatter.
fn auth_persist_tree(
  original : Map[String, LocalYaml],
  host : String,
  user : String,
  token : String?,
  cleanup_pending : Bool,
  git_protocol : String?,
) -> Map[String, LocalYaml] {
  let root = auth_copy_yaml(original)
  let values = match root.get(host) {
    Some(Mapping(values)) => values
    _ => Map([])
  }
  let users = match values.get("users") {
    Some(Mapping(users)) => users
    _ => {
      let users : Map[String, LocalYaml] = Map([])
      if local_get(values, "user") is Some(prior_user) {
        let prior : Map[String, LocalYaml] = Map([])
        if local_get(values, "oauth_token") is Some(prior_token) {
          prior["oauth_token"] = Scalar(prior_token)
        }
        if local_get(values, "keyring_cleanup_pending") == Some("true") {
          prior["keyring_cleanup_pending"] = Scalar("true")
        }
        users[prior_user] = Mapping(prior)
      }
      users
    }
  }
  let account = match users.get(user) {
    Some(Mapping(account)) => account
    _ => Map([])
  }
  match token {
    Some(token) => {
      account["oauth_token"] = Scalar(token)
      values["oauth_token"] = Scalar(token)
    }
    None => {
      account.remove("oauth_token")
      values.remove("oauth_token")
    }
  }
  if cleanup_pending {
    account["keyring_cleanup_pending"] = Scalar("true")
  } else {
    account.remove("keyring_cleanup_pending")
  }
  values.remove("keyring_cleanup_pending")
  users[user] = Mapping(account)
  values["users"] = Mapping(users)
  values["user"] = Scalar(user)
  if git_protocol is Some(value) {
    values["git_protocol"] = Scalar(value)
  }
  root[host] = Mapping(values)
  root
}

///|
async fn auth_persist_login(
  directory : String,
  host : String,
  user : String,
  token : String,
  root : Map[String, LocalYaml],
  backend : CredentialBackend?,
  insecure_storage : Bool,
  git_protocol : String?,
  save? : async (Map[String, LocalYaml]) -> Unit,
  timeout_ms~ : Int32 = 15000,
) -> @github_cli.Output {
  let save = save.unwrap_or_else(() => {
    values => local_write_yaml(directory, "hosts.yml", values)
  })
  let original = auth_copy_yaml(root)
  let existing = match root.get(host) {
    Some(Mapping(values)) => values
    _ => Map([])
  }
  let existing_keyring = auth_account_names(existing).contains(user) &&
    (
      auth_account_token(existing, user) is None ||
      auth_account_cleanup_pending(existing, user)
    )
  let prior = if !insecure_storage && backend is Some(backend) {
    @async.with_timeout(timeout_ms, () => backend.read_async(host, user)) catch {
      err if @async.is_being_cancelled() => raise err
      _ => None
    }
  } else {
    None
  }
  if existing_keyring && !insecure_storage && prior is None {
    return local_error(
      "existing system credential could not be read; account credentials were not changed",
    )
  }
  // Honor cancellation before mutating either store. Credential operations
  // and file writes have deadlines; the shield lets atomic rename or
  // rollback finish before cancellation propagates. OAuth and identity
  // requests are outside this small protected transaction.
  @async.pause()
  let output = @async.protect_from_cancel(() => {
    let attempted = !insecure_storage && backend is Some(_)
    let stored = if attempted && backend is Some(backend) {
      @async.with_timeout(timeout_ms, () => {
        backend.write_async(host, user, token)
      }) catch {
        _ => false
      }
    } else {
      false
    }
    // A false result may follow an actual write whose read-back failed.
    // Keep a recovery marker even when we fall back to a plaintext token.
    let pending = !stored && (attempted || existing_keyring)
    let updated = auth_persist_tree(
      original,
      host,
      user,
      if stored {
        None
      } else {
        Some(token)
      },
      pending,
      git_protocol,
    )
    let saved = try {
      // local_write_yaml bounds the write before its protected atomic
      // rename. Do not wrap rename in a second timeout: a timer winning
      // after rename committed could incorrectly trigger keyring rollback.
      save(updated)
      true
    } catch {
      _ => false
    }
    if !saved {
      let restored = if attempted && backend is Some(backend) {
        @async.with_timeout(timeout_ms, () => {
          match prior {
            Some(previous) => backend.write_async(host, user, previous)
            None => backend.delete_async(host, user)
          }
        }) catch {
          _ => false
        }
      } else {
        true
      }
      if !restored {
        // The prior YAML tree may not reference a newly created credential.
        // Retain a recovery reference where possible, without adding a new
        // plaintext token to the failure path or discarding other accounts.
        let recovery = auth_persist_tree(
          original,
          host,
          user,
          auth_account_token(existing, user),
          true,
          None,
        )
        let recovery_saved = try {
          save(recovery)
          true
        } catch {
          _ => false
        }
        return local_error(
          if recovery_saved {
            "failed to write GitHub credentials; system credential rollback could not be confirmed; a recovery account reference was kept"
          } else {
            "failed to write GitHub credentials; system credential rollback could not be confirmed and a recovery reference could not be saved; inspect the system credential store before retrying"
          },
        )
      }
      return local_error(
        "failed to write GitHub credentials; prior credential state was restored",
      )
    }
    @github_cli.Output::new(
      stdout="✓ Logged in to " + host + " account " + user + "\n",
      stderr=(if stored {
          ""
        } else if insecure_storage {
          "Authentication credentials saved in plain text (--insecure-storage).\n"
        } else {
          "Warning: system credential storage is unavailable; credentials were saved in plain text in hosts.yml.\n"
        }) +
        (if pending {
          "Warning: system credential cleanup remains unconfirmed; the account retains a recovery reference for logout.\n"
        } else {
          ""
        }),
    )
  })
  // A cancelled caller observes cancellation only after durable state has
  // been committed or recovery has finished.
  @async.pause()
  output
}
