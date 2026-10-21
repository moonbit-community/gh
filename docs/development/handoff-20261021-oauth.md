# Mac OAuth、Keychain 与 deploy key 验收（2026-10-21）

## 结果与范围

在 `master`、基线 `c1b8712ab01fa9debd5d8d4bdba643371bb5bd15`
及现有未提交修复上，完成专用 OAuth App 的真实设备码登录、浏览器回调登录、
macOS Keychain 存取删除，以及前一轮因权限不足而未验收的 deploy key
成功生命周期。用户选择的登录账号是 `ZSeanYves`；仓库写操作仅涉及
`ZSeanYves/gh_test`。

最终二进制 SHA-256：
`4f577d66e89803bb9e3b4c80ba3a562364488a0b3fa1495d749d782a1ba49b38`。
固定 oracle 为 GitHub CLI v2.102.0 macOS arm64，二进制 SHA-256：
`8a4258433c81106343144857750316241759d06dcf16265cf3c4864a8f2f2ad6`。
沿用前一轮已核对官方 archive checksum 的 oracle。

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| Device OAuth + Keychain | 通过 | [oauth-device.json](../compat/mac-20261021/oauth-device.json) |
| Web callback OAuth + Keychain | 通过 | [oauth-web.json](../compat/mac-20261021/oauth-web.json) |
| Deploy key 文件只读 / stdin 可写生命周期及差分 | 2 passed，清理通过 | [live-deploy-keys.json](../compat/mac-20261021/live-deploy-keys.json) |
| 最终 binary 真实只读差分 | 20 passed / 0 failed | [live-read.json](../compat/mac-20261021/live-read.json) |
| 四 target 回归 | Native 278、Wasm 69、Wasm-GC 52、JS 69，全部通过 | [summary.json](../compat/mac-20261021/summary.json) |
| 接口、格式、release build | 通过；`.mbti` 无变化 | [源码 hash](../compat/mac-20261021/tested-source-sha256.json) |

四 target 数量来自本次本机命令成功输出，不是 hosted CI。以上 OAuth
与 deploy key、只读报告均对应同一最终 binary。前一轮 59 passed /
10 skipped 的完整写矩阵未在本次 binary 上重跑，仍只对应
[2026-10-20 记录](handoff-20261020-mac-repairs.md) 的 binary。
`core_parity_verified=false`，当前改动未提交、未推送。

## 本次实际发现并修复

1. **OAuth 请求忽略代理环境变量。** 本机到 GitHub OAuth endpoint
   的直连超时，而使用既有代理的请求成功。原生 transport 现在读取
   HTTPS/HTTP/ALL_PROXY 及 NO_PROXY 配置，复用 MoonbitHTTP URI
   解析和上游 async/http CONNECT，不另写隧道或 TLS 实现。受控测试
   覆盖选择顺序、域名边界、静态错误及 CONNECT 不携带源站 Authorization；
   真实设备码与回调流程验证了本机代理路径。支持范围见
   [transport-status](../compat/transport-status.md)，不声称完整代理兼容。
2. **写入 Keychain 后，后续命令无法读取登录状态。** 登录持久化会产生
   `users: {account: {}}` 对应的块式 YAML，其中账户节点为 `{}`；
   token 解析器此前把这个合法的空账户节点当作不支持的 flow mapping。
   现在只在 `host → users → account` 位置接受空 `{}`，保持其他 flow
   mapping 的拒绝策略，也不会误选非活动账户的 token。新增跨命令测试
   先复现失败，再验证 login → token/status；真实 API 调用确认修复。

中间失败报告保存在 [attempts](../compat/mac-20261021/attempts/)：
初始与重试登录失败；仅修复代理的版本能登录并存入 Keychain，但随后
status/API 不通过。它们没有计入最终通过数；本地清理及日常配置保护
均单独记录。

## 真实认证与清理断言

每种流程都使用新的 `GH_CONFIG_DIR`，清除 PAT 等环境 token，并在开始前
确认 `github.com / ZSeanYves / gh-moonbit` 专用 Keychain 项不存在。
配置目录隔离不能隔离同一 host/account 的 OS 凭据，不能省略这项检查。

登录后验证：

- `auth status --json hosts` 为 `ZSeanYves`、`keyring`、`success`。
- 不传环境 token 的 `api user` 返回 `ZSeanYves`。
- 系统 Keychain 项存在，`hosts.yml` 不包含 `oauth_token`。
- `auth logout --user ZSeanYves` 后系统项消失，`auth token` 无输出并失败。
- 日常 `~/.config/gh/hosts.yml` 和 `config.yml` 的 hash 前后相同。

两种流程结束后，通过专用 App 的 grant 删除接口取得 HTTP 204，
撤销该 App 对测试账号的授权。设备报告中的
`remote_app_authorization_revoked=false` 表示撤销尚待后续 web 流程统一执行；
web 报告中的 `true` 是最终远程清理结果。App 注册、Client ID/Secret
文件和仓库测试 PAT 保留，后续验收仍可重新授权。

报告不保存 token、Client Secret、设备码或回调查询。测试 PAT 和 App
Secret 的精确值扫描通过；凭据只在本机文件、子进程环境/stdin 或
Keychain 内使用，不写入报告、源码或命令参数。

Deploy key 测试分别验证文件输入默认只读和 stdin 加 `--allow-write`，
核对真实对象状态并与 oracle 比较退出码和输出；报告确认测试 key
已删除，`residual_resources=[]`。

## 复跑入口与后续准备

本次本机入口保存在忽略目录 `_build/acceptance-20261021/`：
`oauth_acceptance.mbtx` 从用户本机的 OAuth JSON 读取凭据，`device`/
`web` 参数选择流程，可加新的重试标签保留已有证据；web 成功后会撤销
专用测试 App 的授权。运行需要用户参与浏览器授权，不应放入 CI。

通用手动步骤见 [auth-acceptance](auth-acceptance.md)。只读与 deploy key
runner 分别为 `scripts/live_github_fixture.mbtx` 和
`scripts/live_github_repair_fixture.mbtx --deploy-keys-only`；凭据由本机
入口注入，固定 oracle 校验策略沿用前一轮。

已完成当前准备，无需用户再修改 Token 权限或重建 OAuth App。后续：

- 可以继续在本机实现 formatter、Actions 日志/下载及已有受控 fixture
  明确列出的缺口；本次未执行 Actions workflow/run 生命周期，不把新增
  Actions/Workflows 权限等同于功能通过。
- 真实多账号切换、组织/environment、Enterprise，以及 Linux/Windows
  OS keyring 仍需要对应账号或环境；可以按用户要求暂缓。
- Refresh-token rotation、自动 device-to-web fallback、完整 TTY/watch
  等仍按既有交接跟踪。本次专用 App 关闭 token 过期，不覆盖 refresh
  token 路径。
- hosted 三平台 CI 必须在后续推送实际源码后重新读取结果；当前本机
  四 target 通过不替代该门禁。
