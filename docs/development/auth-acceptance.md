# OAuth, keyring and account acceptance

As of 2026-10-21. This guide applies to the executable built from this
working tree. Controlled tests do not establish real GitHub authorization or
OS credential-store acceptance. Keep credentials outside the repository,
command arguments, CI, reports and conversation messages.

The [Mac acceptance record](handoff-20261021-oauth.md) now confirms real device
and browser-callback login for the selected `ZSeanYves` test account, Keychain
store/read/delete, identity verification without an environment token, and
remote test-App grant revocation. Linux, Windows, and multiple real accounts
remain separate acceptance gates.

## Implemented boundaries

- Device authorization: code presentation, optional clipboard, browser/manual
  fallback, polling, slow-down handling, denial, expiration and cancellation.
- Web authorization: random state, S256 PKCE, a bounded 127.0.0.1 callback,
  Host/state validation, token exchange, timeout and listener cleanup.
- Login verifies the authorized GitHub account before storage. Refresh
  preserves existing scopes, supports add/remove/reset and rejects an account
  mismatch. Environment tokens must be unset before storing credentials.
- Linux secret-tool, macOS git credential-osxkeychain, and Windows
  git credential-wincred adapters use stdin and a restricted environment.
  Writes/deletes require read-back confirmation. Missing helpers produce an
  explicit plaintext fallback warning. --insecure-storage bypasses keyring.
- Gist file mutations, SSH authentication/signing keys, GPG public-key input,
  basic Projects V2 operations and account status have controlled tests.

These are implementation boundaries, not a claim of full command/TTY parity.
Refresh-token rotation is not implemented; expiring OAuth token responses are
rejected before storage. Real account mutations have not been performed.

## 1. Prepare the desktop host

On Ubuntu, install the Secret Service helper in your normal logged-in
desktop terminal:

```bash
sudo apt install libsecret-tools
command -v secret-tool
```

Keep your Secret Service collection unlocked; complete any unlock dialog
locally. Do not run the CLI as root. A plaintext fallback warning means the
keyring acceptance has not passed, even if login succeeds.
If cleanup is reported as unconfirmed, keep the account reference and repair
the OS helper/session before retrying logout; do not delete configuration to
hide the warning.

macOS needs the credential-osxkeychain Git helper and unlocked user Keychain.
Windows needs the credential-wincred Git helper (not Git Credential Manager).
The macOS helper passed the 2026-10-21 acceptance; Windows remains unverified.

## 2. Register a dedicated test OAuth App

GitHub: Settings → Developer settings → OAuth Apps → New OAuth App.
Use a test name such as MoonBit gh local acceptance and this project's
repository as homepage. Set Authorization callback URL to:

```text
http://127.0.0.1/callback
```

Enable Device Flow. Expire user access tokens is enabled by default; disable
it for this dedicated test App because this build does not yet rotate refresh tokens.
That makes the credential longer-lived; revoke the test authorization after
acceptance. Do not change a production App's expiration policy for this test.

Copy the Client ID. Device authorization uses this public ID and needs no
Client Secret. Only the separate browser callback flow needs a Client Secret;
keep that locally and never send it in chat.

GH_OAUTH_FLOW selects the protocol. The --web login flag by itself does not
switch to authorization-code flow, and device mode never requires a Client
Secret. Keep callback wildcard matching disabled on the App.

## 3. Build and authorize via device flow

From the repository root, in the same desktop terminal:

```bash
moon build --target native --release --frozen --deny-warn cmd/main
export GH_CONFIG_DIR="$HOME/.config/gh-moonbit-acceptance"
export GH_HOST=github.com
export GH_OAUTH_CLIENT_ID='YOUR_TEST_APP_CLIENT_ID'
export GH_OAUTH_FLOW=device
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
unset GH_KEYRING_COMMAND GH_OAUTH_CLIENT_SECRET
./_build/native/release/build/cmd/main/main.exe auth login --hostname github.com --web --git-protocol https
./_build/native/release/build/cmd/main/main.exe auth status --hostname github.com
```

Enter the displayed one-time code in GitHub and authorize the App. Default
scopes match the pinned CLI: repo, read:org and gist. The login is obtained
from GitHub; no synthetic default identity is stored. Successful OS storage
appears as keyring in auth status. Do not share auth token or --show-token
output. The separate configuration directory protects your normal account
list, but OS stores are keyed by host/account independently of that directory.
This implementation's macOS item also uses the `gh-moonbit` path. Check that
the selected test account has no existing project credential before starting
an acceptance run; configuration isolation alone does not protect that item.

## 4. Verify browser callback authorization

Keep the same Client ID and callback URL. In interactive Bash, enter the
secret without echoing it or placing it in history:

```bash
read -r -s -p 'Test OAuth App client secret: ' GH_OAUTH_CLIENT_SECRET
export GH_OAUTH_CLIENT_SECRET
export GH_OAUTH_FLOW=web
./_build/native/release/build/cmd/main/main.exe auth login --hostname github.com --web
unset GH_OAUTH_CLIENT_SECRET
export GH_OAUTH_FLOW=device
```

The CLI chooses a free loopback port, which GitHub allows for a registered
loopback callback. The browser must run on the same machine as the CLI.
The browser's response page only confirms receipt; terminal login success
also confirms token/identity verification.

## 5. Account capability permissions

Add permissions only for the lifecycle being verified, using auth refresh
--scopes. Start with read-only tests. No additional PAT is needed for features
already covered by the authorized OAuth scopes.

| Capability | OAuth scope |
| --- | --- |
| Gist lifecycle | gist (included at login) |
| Projects read / write | read:project / project |
| SSH authentication keys read / add-delete | read:public_key / admin:public_key |
| SSH signing keys read / add-delete | read:ssh_signing_key / admin:ssh_signing_key |
| GPG keys read / add-delete | read:gpg_key / admin:gpg_key |
| Status notifications | notifications when other scopes do not grant access |

Example read-only start:

```bash
./_build/native/release/build/cmd/main/main.exe auth refresh --hostname github.com --scopes read:project,read:public_key,read:ssh_signing_key,read:gpg_key,notifications
./_build/native/release/build/cmd/main/main.exe gist list
./_build/native/release/build/cmd/main/main.exe project list --owner @me
./_build/native/release/build/cmd/main/main.exe ssh-key list
./_build/native/release/build/cmd/main/main.exe gpg-key list
./_build/native/release/build/cmd/main/main.exe status
```

Real mutations need an explicitly selected test account and disposable marker
resources. Upload only public test keys, never private keys. Organization
Projects additionally depend on organization policy and authorization.
Two synthetic accounts already cover local switch/logout policy; you need
not create another real account just to run those tests.

## 6. Cleanup and evidence

After the agreed test account's acceptance, logout with its exact login:

```bash
./_build/native/release/build/cmd/main/main.exe auth logout --hostname github.com --user YOUR_TEST_LOGIN
```

Logout removes local credentials; revoke the test App under GitHub Settings
→ Applications → Authorized OAuth Apps to invalidate remote authorization.
Reports should contain pass/fail, platform, source/binary hashes and cleanup,
never tokens, device codes, callback queries or client secrets.

Real device/web OAuth consent and macOS Keychain store/read/delete passed
on 2026-10-21. The dedicated App grant was revoked after both flows; the App
registration was preserved. Linux/Windows host acceptance and multi-account
acceptance remain pending.

Remaining compatibility work includes automatic device-to-web fallback,
refresh-token rotation, interactive gist editing/clone/web, gist list pagination,
Projects item/field management, and exact account status terminal formatting.

## Sources

- https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps
- https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app
- https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps
- https://docs.github.com/en/rest/users/ssh-signing-keys
- https://github.com/cli/cli/blob/v2.102.0/internal/authflow/flow.go
- https://git-scm.com/docs/git-credential
- Local fixtures: native/github_auth_oauth*_test.mbt,
  native/github_auth_login_test.mbt, native/github_auth_keyring_wbtest.mbt,
  native/github_auth_accounts_test.mbt, native/github_business_account*_test.mbt.
