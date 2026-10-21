# GitHub core parity：Mac 续作交接（2026-10-19）

后续修复和 Mac 真实差分见
[2026-10-20 记录](handoff-20261020-mac-repairs.md)。本文保留交接时状态；
其中的错误路由/语义风险和旧 binary 结果不能代替后续记录。

## 结论和续作位置

- 项目：`moonbit-community/gh`；远端 `git@github.com:moonbit-community/gh.git`。
- 继续在 `master` 工作，`codex/moonhub-adapter` 保持冻结。测试仓库是
  `ZSeanYves/gh_test`，不是代码发布远端。
- 固定兼容目标仍为 GitHub CLI **v2.102.0**；不随最新版改变目标。
- 本轮基于 `fb79c88b276e5bca07ce8abda36db440e643ce8a`，本报告与所有实现、
  测试和脱敏结果随同一次提交保存。用 `git log -1` 获取最终提交号。
- **core_parity_verified=false。当前远不止最后一次登录测试：仍有功能缺口、
  全命令差分、非空数据、真实主机和跨平台验收需要完成。没有足够的逐命令
  验收矩阵支持一个可信的完成百分比。**
- 本文接替 `handoff-20261018.md`。旧报告中“variable 写权限不足”的推断已被
  推翻；PR review/merge、release download 和 repository secret/variable
  生命周期现已有真实通过证据，不能继续按旧报告重复列为未完成。

## 已经做了什么

### 架构、工具链与基础协议

- `master` 只包含 GitHub CLI/SDK；入口 `cmd/main`，原始 HTTP/GraphQL 在
  provider/transport 层，解析输出在 `github_cli`，OS 适配在 `native`。
- 工具链与 CI 固定 MoonBit release `0.1.20261012`、compiler/core
  `0.10.15+943464bfa`；依赖版本以 `moon.mod` 为准。
- 原始字节、重复 headers、REST/GraphQL、错误分类、分页、trace 脱敏、
  取消以及 argv-only Git/editor/browser/process 边界有受控测试。
- 已捕获 v2.102.0 oracle 275 个快照，其中 229 个命令 help。
  这些是参考语料，不等于 229 个命令实现或完整差分通过。

### 本轮仓库写操作修复与实测

- Variable set 修正为先 POST collection，仅在 409 时 PATCH 指定变量。
  `value` 保持字符串；不能把 `X-Accepted-GitHub-Permissions` 当作 token
  实际权限，也不能把错误方法导致的 404 当成只读凭据。
- Secret 使用 GitHub 公钥和 sealed-box 加密，已有固定向量与真实仓库
  set/list/delete 验证；没有在报告中写入秘密值。
- PR merge 策略、head SHA 条件和后续状态检查已实现。真实测试使用两条
  marker 分支验证合并 SHA/文件内容，没有改变测试仓库默认分支。
- Release 通过 numeric ID 修改/删除；upload 校验 uploads origin；
  download 保留二进制并校验有限重定向，不向跨 origin CDN 发送 API token；
  delete-asset 按 tag + asset name 精确定位。实测下载字节一致。
- live write runner 增强清理和报告；新旧变量值仅内存比较。

### OAuth、系统密钥环和账户级功能

- Device flow：用户码、浏览器/手工打开、可选剪贴板、轮询、slow_down、
  denied/expired/cancel；默认使用设备码流程。
- Web flow：随机 state、S256 PKCE、临时 `127.0.0.1` callback、
  Host/path/state 检查、有限请求体/超时和监听器清理。
- `GH_OAUTH_CLIENT_ID` 必填；`GH_OAUTH_FLOW=device|web` 选择协议。
  `--web` 本身不切换到 code flow；只有 flow=web 还需要 Client Secret。
- Login 调用 `/user` 验证真实身份后保存；refresh 保留/增减/reset scopes，
  拒绝换成另一个账户。环境 token 会阻止持久化登录/refresh。
- Linux `secret-tool`、macOS `git credential-osxkeychain`、Windows
  `git credential-wincred` 适配已实现。Windows 不是 GCM。
  token 走 stdin，子进程环境受限，读回确认写入/删除。
- hosts.yml 私有临时文件 + 原子替换；取消时完成提交或回滚，旧凭据不可读
  时拒绝覆盖，回滚不确定时明确报错并保留恢复标记，logout 不隐瞒清理失败。
- 多账户 switch/logout/status/token 有 synthetic fixtures。
- Gist 文件创建/修改/增加/删除/重命名，SSH authentication/signing keys，
  GPG 公钥输入，Projects V2 基本 create/list/view/edit/close/reopen/delete，
  status assignment/review/mention/activity 聚合均有实现和受控测试。

## 已验证证据与不能外推的部分

| 证据 | 结果 | 适用范围 |
| --- | --- | --- |
| 本轮最终 Linux Native | 259/259；warning-denied check、release build、info、fmt 均通过 | 当前实现的单元/loopback/process fixtures |
| 本轮 portable | Wasm 68、Wasm-GC 51、JS 68，全部通过 | portable packages，不是这些 target 的原生 OAuth CLI |
| 2026-10-19 repository live | 59 passed / 10 skipped / 0 failed；cleanup passed | 下方旧 live binary，只证明实际执行的生命周期 |
| 2026-10-17 read-only differential | 20/20 | 更早的 binary；不能证明当前提交已重新通过 |
| 真实 OAuth / OS keyring / 账户写操作 | 未执行 | 需要用户授权与对应主机 |

- 最新 Linux release SHA-256：
  `8f5b9d4872922f77087cd5bdda6d23418fa244786709c11f3c1f899861b30f99`。
- 较早 repository live binary SHA-256：
  `9d6c5e9258f40031245b1a2c8845819a0b0ba03d2d3ff2ea5288bf4aa3960e9c`。
- 保留报告：[auth-account-20261019.json](../compat/auth-account-20261019.json)、
  [live-write-20261019.json](../compat/live-write-20261019.json)。
  auth 报告的 dirty/committed=false 描述**验证时**状态，不是推送后状态。
- 真实写操作清理无活动残留；已合并 PR 历史仍可见，没有声称删除 PR 历史。
- 10 个 skips：repo-description-edit（原值为 null）；workflow dispatch、
  run view/logs/artifacts/cancel/rerun/watch/exit-status 共 8 项；cache 创建。
- 本次推送触发的 hosted CI 尚须查看实际结果，尤其 macOS/Windows。
  本机测试通过不等于三平台 CI 已通过。

## 距离 core parity 还差什么

### A. 明确的实现缺口

1. OAuth expiring access token 的 refresh-token rotation；当前明确拒绝这类
   响应。Device→web 自动 fallback 尚未实现。
2. Gist 交互 editor、clone/web、truncated raw retrieval、多页 list limits；
   Projects item/field 管理以及 inventory 中其余未覆盖操作；status 精确布局、
   排序/limits/cache 和部分权限失败恢复。
3. 完整 core formatter：目前只支持确定性子集。需对固定 JSON fixture 将
   原计划的 jq 表达式及 Go-template 函数逐项与 v2.102.0 比较，不能写成
   “有 jq/template 就已完整”。补 assignment/重建、插值和错误分支等缺项；
   template 的变量/pipeline/time/Sprig/TTY 行为以实际差分决定。
4. Discussion mutations；organization variable selected-repository 访问；
   config clear-cache、shell alias 执行与扩展感知校验；完整 YAML/序列化兼容。
5. Release archive/checksum/verify 等 inventory 中剩余选项；现有下载仅有限
   glob/16 MiB native response limit，跨 origin Enterprise object store 未覆盖。
6. Repo context 的 SSH host alias、IPv6、remote push URL、percent-decoding、
   交互 remote 选择与精确诊断；现有 remote precedence 仍需 oracle 验证。
7. PR checkout/review、run watch/log streaming 等完整交互体验。命令 inventory
   其他行仍须逐项检查；本列表不是穷尽审计，也不把 help 当作实现。
8. 当前分派还缺 repo autolink/set-default、label clone、release verify/
   verify-asset。run download 目前只列出 artifacts，未实现 ZIP 下载/落盘/
   解包；run view --log 的完整下载与展示也待补。completion 只有
   bash/zsh/fish 顶层词，缺完整子命令/flags 和 PowerShell；业务 help
   仍有精简静态输出，不能声称全部 help 字节一致。

另有**必须先核实和修正的语义风险**，不能只安排补线上证据：

- `pr checks` 当前将 PR 编号当 commit ref，需先解析 PR head SHA。
- `pr status` 当前按单个编号读取 PR，缺上游账户相关聚合；`issue status`
  只列 repository open issues，缺完整分类。
- `issue pin/unpin/develop`、`pr revert` 的 extra 映射存在推定 REST 路由，
  现有测试只断言相同字符串，尚不能证明 GitHub 接受；应核对 pinned
  source/成功 fixture，不能以这些测试通过作为完成证据。
- `pr update-branch --rebase` 的请求体及 deploy-key add 文件/stdin 契约
  仍需按 oracle 校验。

这些来自当前源码的只读审计，尚未为本次交接新发真实 API 请求。后续先把
它们列为矩阵中的 blocked/unknown，修正后再给对应命令打勾。

### B. 已有部分实现，但验收尚未闭合

1. 对**新构建的 Mac binary**重跑 20 项 read-only differential；再扩展非空
   repo/issue/PR/release/run/workflow/search/org/label/ruleset/secret/variable/
   GraphQL project/discussion profiles。必须比较类型、顺序、null/缺失等，
   不能通过统一大小写或只比较数量掩盖差异。
2. REST Link / GraphQL cursor 多页、重复 cursor/link、防跨 origin、
   paginate/slurp、rate-limit，以及错误码/stderr/trace 的完整差分矩阵。
3. Marker workflow/run/artifact/cache 的可清理生命周期。当前 runner
   **仍主动 skip**，只重新运行不会自动补全；先实现 fixture setup/cleanup
   和 case。Cache 无法安全创建时按原计划使用明确的 loopback acceptance。
4. Secret/variable 的 organization/environment 真实路径与权限边界，
   selected repositories 的功能和测试；repo description null 恢复语义。
5. 真实 device/web consent、Keychain store/read/delete、refresh、账户切换
   与失效/锁定场景；真实 gist/keys/projects 的有界生命周期。
6. PTY prompt/确认/stdin/exit code，editor 优先级、browser opener、TLS trust
   与坏证书拒绝，文件权限/ACL、取消和进程退出的主机验收。
7. 固定工具链在干净 checkout 重复四 target gate；查看 Linux/macOS/Windows
   CI 的实际结果。当前 CI 没有运行 write runner self-test，Mac 手工门禁
   要运行它，后续补齐 CI gate。

### C. 完成定义

先建立逐命令/子命令/关键 flag 的验收矩阵，包含 parser、request/response、
stdout/stderr、exit code、trace、fixture/golden、适用的 TTY/host/cross-target
case 和证据路径。未审计标 unknown；skip 不等于 pass。所有 core 行通过，
非空差分和写清理通过，新 binary 的报告完整，才允许改 core_parity_verified。

以下特殊 integrations 仍独立延期，**不阻塞本轮 core milestone**：codespace、
copilot、agent-task、attestation、extension、skill/skills、send-telemetry、
preview/accessibility。它们未经独立验收不得宣称 full built-in parity。

## Mac 上建议按这个顺序继续

### 1. 拉取代码并复现构建

已有 checkout：

```bash
git switch master
git pull --ff-only origin master
git status --short
git log -1 --oneline
```

新机器先 `git clone git@github.com:moonbit-community/gh.git`，再进入目录。
按 [.github/workflows/ci.yml](../../.github/workflows/ci.yml) 配置相同 MoonBit
compiler/core、C toolchain 和 Git。先检查 `moon version --all`；不要直接升级
依赖或把最新版 GitHub CLI 当 oracle。Mac 必须重新构建，不能搬 Linux binary。

```bash
moon update
moon check --target native --frozen --deny-warn
moon test --target native --frozen
moon build --target native --release --frozen --deny-warn cmd/main
moon run --target native scripts/live_github_fixture.mbtx -- --self-test
moon check --target native --deny-warn scripts/live_github_write_fixture.mbtx
moon run --target native scripts/live_github_write_fixture.mbtx -- --self-test
moon info
moon fmt --check . scripts/gh_oracle.mbtx scripts/live_github_fixture.mbtx scripts/live_github_write_fixture.mbtx
git diff --exit-code -- '*.mbti'
```

继续执行 [release.md](release.md) 中 Wasm/Wasm-GC/JS checks/tests。Moon 命令
顺序执行，避免共享 build lock；代码更改后按 AGENTS 执行 `moon info`、
`moon fmt` 并审查 `.mbti`。所有新自动化使用 `.mbtx`，业务源码使用 `.mbt`。

### 2. 先验证 Mac OAuth / Keychain

- 确保 Git 的 `credential-osxkeychain` helper 可用且登录 Keychain 已解锁。
  不要把 Linux 的 apt/secret-tool 步骤照搬到 Mac。
- 自己创建专用测试 OAuth App：callback `http://127.0.0.1/callback`、
  启用 Device Flow、关闭 callback wildcard。当前尚不支持 token rotation，
  仅对测试 App 关闭默认开启的 Expire user access tokens，验收后撤销授权。
- Client ID 可公开；Client Secret/token/私钥始终只保存在本机，不发聊天。
- 先进入 Bash，后面的无回显输入示例使用 Bash；不要在 zsh 直接照搬
  `read -r -s -p` 的 Bash 语法。

```bash
bash
export GH_CONFIG_DIR="$HOME/.config/gh-moonbit-acceptance"
export GH_HOST=github.com
export GH_OAUTH_CLIENT_ID='YOUR_TEST_APP_CLIENT_ID'
export GH_OAUTH_FLOW=device
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
unset GH_KEYRING_COMMAND GH_OAUTH_CLIENT_SECRET
./_build/native/release/build/cmd/main/main.exe auth login --hostname github.com --web --git-protocol https
./_build/native/release/build/cmd/main/main.exe auth status --hostname github.com
```

浏览器完成用户码授权；status 必须显示 keyring。若明文 fallback，不能判
Keychain 验收通过。GH_CONFIG_DIR 仅隔离配置，OS 凭据仍按 host/account
索引；尽量使用选定的测试账户。随后按 [auth-acceptance.md](auth-acceptance.md)
运行 web flow、scope refresh、注销和 GitHub App 授权撤销。不要分享
`auth token` 或 `auth status --show-token` 输出。

### 3. 补新 binary 的差分证据和未覆盖写场景

- 获取适合 Mac 架构的 v2.102.0 oracle 并核验发行来源/校验和。Linux oracle
  hash 不适用于 Mac。`GH_ORACLE_SHA256` 是实际 oracle executable 的 hash，
  不是压缩包 hash；Mac 可用 `shasum -a 256`。
- 用新文件路径记录报告；旧 runner 会拒绝覆盖已有报告。
- 仅在 `ZSeanYves/gh_test` 运行真实仓库写测试；先 read-only，再 marker
  lifecycle。通过 GitHub 对应 resource permission 配置令牌，不从响应头
  推断已有权限。Actions 新场景需要 Actions write 及 workflow 文件写权限。

在本机 Bash 交互输入测试仓库 token；此 token 和 OAuth/Keychain 验收分开：

```bash
read -r -s -p 'Test repository token: ' GH_TOKEN
export GH_TOKEN
export LIVE_GITHUB=1
export GH_HOST=github.com
export GH_LIVE_REPO=ZSeanYves/gh_test
export GH_ORACLE_BINARY='/absolute/path/to/verified-gh-v2.102.0'
export GH_ORACLE_SHA256='VERIFIED_MAC_EXECUTABLE_SHA256'
moon run --target native scripts/live_github_fixture.mbtx -- _build/native/release/build/cmd/main/main.exe _build/live-read-mac-01.json
moon run --target native scripts/live_github_write_fixture.mbtx -- _build/native/release/build/cmd/main/main.exe _build/live-write-mac-01.json
unset GH_TOKEN LIVE_GITHUB GH_LIVE_REPO GH_ORACLE_BINARY GH_ORACLE_SHA256
```

先替换占位值，read-only 失败先修复再执行写测试。write runner 的 oracle
选项不是全写操作双向差分的替代；59 项旧证据也不能填充新矩阵的所有行。
Actions workflow dispatch 对 workflow 默认分支可发现性有要求；先设计
可恢复的 marker workflow 方案，不盲目修改默认分支或删除现有 workflow。

### 4. 补功能矩阵，再收尾验收

推荐顺序：OAuth/Keychain 实机 → formatter oracle table → Projects/gist/
discussion/其他 core 缺口 → 非空分页 profiles → Actions/cache 生命周期 →
PTY/editor/browser/TLS → clean checkout + 三平台 CI + 总报告。
每完成一片更新矩阵和证据，不要靠增加测试数量宣称兼容率。

## 下一轮需要用户提供什么

| 项目 | 用户需要准备 |
| --- | --- |
| Mac 环境 | 同版本工具链、Git helper、可解锁 Keychain 的桌面会话 |
| OAuth | 专用测试 OAuth App Client ID；亲自浏览器授权；web flow 的 Secret 仅本机输入 |
| 账户生命周期 | 指定测试账户及允许使用的临时 gist/project/公钥资源；绝不提供私钥 |
| Repo/Actions | `ZSeanYves/gh_test` 的测试 token；补足对应 repository/Actions/workflow 权限 |
| Org/environment | 只有要验收这些路径时才需测试组织/环境和对应权限；没有则明确 pending |
| Windows 真机 | 之后需 Credential Manager + wincred helper 环境；Mac 不能代替该验收 |

不需要另建真实第二账号来重跑 synthetic 多账户单测。不要将 Linux
`gh_test_key.json`、hosts.yml、Keychain 内容或 `.codex` 会话文件提交/拷贝到
仓库；Mac 用自己的安全存储。普通 CI 不接收真实账户 token。

## 文件导航与恢复规则

- OAuth：`native/github_auth_oauth*.mbt`；身份：`github_auth_identity.mbt`。
- Keyring/persistence：`native/github_auth_keyring*.mbt`、
  `github_auth_persistence*.mbt`、`github_local.mbt`、`github_auth_accounts.mbt`。
- Account：`native/github_business_account*.mbt`。
- Release/variable/PR：`github/release_download*.mbt`、
  `native/github_business_release_assets*.mbt`、`github_business_variables*.mbt`、
  `github_business_pr_merge*.mbt`。
- Formatter：`github_cli/output.mbt` 及测试。Oracle：
  `testdata/gh-oracle/v2.102.0/`、`scripts/gh_oracle.mbtx`。
- 架构/验收定义：`docs/architecture.md`、`docs/compat/gh-v2.102.0.md`、
  `oracle-status.md`；细分限制见 `business-status.md`、`credentials-status.md`、
  `repository-status.md`。文档中的历史测试数不代表当前总数。
- `/tmp` 的日志、oracle binary 和代理交接文件不会随 Git 搬到 Mac；本报告和
  仓库内两份 JSON 是持久交接依据。无需恢复旧加密对话即可继续。
- `encrypted content hydration failed` 属于旧会话/传输问题，不能由仓库
  代码保证不再发生。遇到时新开会话，以本报告、git log、文件和测试为依据；
  不要伪造恢复结果或尝试把旧 encrypted item 重新注入。

可复制给下一个会话：

> 请先读 AGENTS.md、docs/development/handoff-20261019-mac.md 和两个
> 20261019 验证 JSON。在 master 延续 v2.102.0 core parity，保持 MoonHub
> adapter 分支不动。先确认当前 commit 与 Mac 工具链，复现门禁并完成
> OAuth/Keychain 实机验收；再建立逐命令矩阵，补 formatter、账户/业务缺口、
> 非空差分与 Actions/cache marker lifecycle。所有自动化用 .mbtx；真实仓库
> 测试仅 ZSeanYves/gh_test。未执行和 skip 必须保留 pending，不能宣称 core
> parity 已完成。用户在本机处理授权/密钥，不要求其将凭据发到聊天。
