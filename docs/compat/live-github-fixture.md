# Live GitHub account fixture

`master` 已拆分为纯 GitHub 主线；原 MoonHub 实现保存在
`codex/moonhub-adapter`。本文的 2026-10-17 真实网络结果属于拆分前已测试的
binary；分支拆分、本地构建和 runner self-test 不构成新的 live 验证。

真实 GitHub 账户网络测试属于手动或 nightly integration gate，不属于普通单测、golden corpus 或 pull request 的默认 CI。它验证真实网络、权限和 GitHub 服务行为；确定性回归仍由 loopback HTTP fixture 和脱敏 cassette 完成。

这里的凭据主要指 GitHub API token。SSH 私钥用于 SSH 协议的 git clone/fetch/push；Issue、PR、Release、Actions 等 API 请求需要 PAT、OAuth token 或适用的 GitHub App token。建议为专用仓库创建有期限、权限受限的 fine-grained PAT，通过 `GH_TOKEN` 注入。被测程序是本项目编译出的 Native CLI；原版 `gh v2.102.0` 只作为独立对照程序。

## 启动条件

测试必须显式设置 `LIVE_GITHUB=1`，并提供一个低权限 fine-grained token 和专用测试仓库：

```text
LIVE_GITHUB=1
GH_TOKEN=<fine-grained-token>
GH_LIVE_REPO=ZSeanYves/gh_test
```

runner 应在启动时拒绝未设置 `LIVE_GITHUB=1`、token 为空、仓库不等于固定白名单 `ZSeanYves/gh_test`，或目标 host 不是 `github.com`。token 只从环境变量读取，不能出现在 argv、trace、错误、日志、快照或 cassette 中。

每次运行都使用新的临时配置目录，并关闭会改变输出或产生外部副作用的功能：

```text
GH_CONFIG_DIR=<temporary-directory>
GH_NO_UPDATE_NOTIFIER=1
GH_TELEMETRY=0
DO_NOT_TRACK=1
GH_PAGER=cat
GH_PROMPT_DISABLED=1
GIT_TERMINAL_PROMPT=0
LC_ALL=C
```

`GH_FORCE_TTY` 应不设置；v2.102.0 的环境帮助说明任意非空值都会强制终端输出，`0` 也不是关闭开关。环境变量依据仓库中的 `testdata/gh-oracle/v2.102.0/help-environment.stdout` 核对。

每个子进程有 45 秒超时和 2 MiB 输出上限；Native HTTP 客户端自身有 30 秒请求超时与 16 MiB 响应上限。当前 runner 固定 20 个只读 probe case；启用 oracle 时，项目和 oracle 各执行一遍同样的 case，因此报告记录 `command_budget` 为 20 或 40。项目每个 probe 必须产生且只产生一条请求 trace；oracle 的业务命令内部可能发出多个 HTTP 请求，不能把执行命令数量当作总请求预算。收到 429 或 secondary rate limit 后立即失败，不等待配额恢复。隔离环境默认不继承本机代理变量；需要代理网络时应先在专用隔离环境中验证连通。

只读 runner 已实现在 [`scripts/live_github_fixture.mbtx`](../../scripts/live_github_fixture.mbtx)。项目 CLI 自身没有 `LIVE_GITHUB` 网络开关；该变量由 runner 强制检查。先编译并测试 runner，然后构建 Native CLI：

```text
moon run --target native scripts/live_github_fixture.mbtx -- --self-test
moon build --target native --frozen cmd/main
```

执行时需要显式设置 `LIVE_GITHUB=1`、`GH_LIVE_REPO=ZSeanYves/gh_test` 和 `GH_TOKEN`。token 不应出现在聊天、终端参数或报告中。每个子进程都在关闭环境继承后单独注入 token，并指向新的临时配置目录；runner 不会使用日常 `hosts.yml` 或 keyring。runner 的 20 个 probe case 全部是只读请求（REST 为 GET，GraphQL 为 POST query），不会创建、编辑、关闭或删除远端资源，遇到首个失败即停止。

默认固定探针包括原有 12 项 `/user`、repository、原始 issues/pulls/releases/runs/workflows、两个 GraphQL query、jq、template、repo view，以及新增的 8 项 repo-details、issue-list、pr-list、release-list、run-list、workflow-list、search-issues、search-repos。repo-details 检查 `name,nameWithOwner,visibility`，暂不将待 oracle 核验的 `defaultBranchRef` 计入；search-repos 只搜索白名单仓库，使用 `fullName`。原始集合端点使用 `per_page=2`，不自动翻页。空列表的报告标记 `nonempty_semantics_verified=false`；它属于有效的连通 smoke，但不证明非空业务行为。分页需要另外比较页数、稳定项目字段和请求链，不能从这个 runner 的通过结果推断。

HTTP 输出通过 CLI `--include` 解析。报告只保留状态码、rate-limit 数值、schema 结果、输出长度、二进制 SHA-256、固定错误类别和脱敏 trace 检查结果。不会写入 body、用户名、标题、issue 内容或原始 stderr。PAT 成功也不证明 OAuth、keyring 或多账户流程；报告会将这些能力标记为未验证。

`workflow list` 的无结果输出是 v2.102.0 的特殊分支：管道模式下 exit code 为 0，stdout/stderr 均为空，即使指定 `--json` 也不会导出 `[]`。runner 将它记为 `output_kind=empty`，与 `output_kind=json` 的 `[]` 严格区分；两者不同仍判失败。只有 workflow probe 接受精确空字符串，空白字符或其他 JSON probe 的空输出仍失败。空输出报告不宣称验证了非空字段或 JSON schema。

运行前例：

```text
LIVE_GITHUB=1 GH_LIVE_REPO=ZSeanYves/gh_test moon run --target native scripts/live_github_fixture.mbtx
```

运行前须在同一个本机终端会话安全地设置 `GH_TOKEN`；不要将 token 粘贴到 Codex 聊天或 shell 命令历史。可以用不回显的交互读取方式输入，然后 `export GH_TOKEN`，测试结束后 `unset GH_TOKEN`。准备 oracle 对照时，先单独验证 `gh v2.102.0` 的 SHA-256，并通过 `GH_ORACLE_BINARY` 与 `GH_ORACLE_SHA256` 指定本地文件。项目与 oracle 会依次执行同一组只读 argv；runner 不重试失败的命令，项目 trace 要求每个 probe 恰有一条成功请求。oracle 的内部请求数不会仅凭输出推断。

以下命令说明 CLI 公开支持的原始请求形式；它们本身不是 runner：

```text
api /user --hostname github.com --jq .login
api repos/OWNER/REPO --hostname github.com --jq .full_name
api graphql --hostname github.com -f 'query=query { viewer { login } }' --jq .data.viewer.login
```

runner 为每个子进程显式传递同一套隔离环境。临时配置目录权限为 0700，执行结束清理；token 缺失时立即失败，不回退到日常账户。本 runner 只做网络 smoke，分页、交互、写操作仍需专门的验收脚本。

## 2026-10-17 真实只读记录

以下是用户在 2026-10-17 提供的本机终端结果，测试仓库为 `ZSeanYves/gh_test`。这是已报告的真实请求证据，和之后扩展到 20 项的 runner 通过记录分开统计；尚未执行的新 case 不算通过。token 没有出现在提供的终端结果中。

- `repo view` 输出 `name=gh_test`、`nameWithOwner=ZSeanYves/gh_test`、`visibility=private`、`defaultBranchRef=null`。这只是当时项目 binary 的输出；可空分支和 visibility 的大小写仍需与固定 oracle 严格对照，不能据此断言仓库为空或字段映射完全正确。
- `issue list --state all --limit 3` 返回此前创建并关闭的 #1、#2、#3；`issue view 1` 返回该测试 Issue 的标题和 body。当时项目输出的 state 是小写 `closed`，业务命令的枚举大小写仍需单独与 oracle 对照。
- `pr list`、`release list`、`run list` 和 `workflow list` 返回空数组。空数组证明 endpoint、认证和响应 envelope 可用；测试仓库没有对应资源，因此不证明非空字段投影或 Actions 业务行为。
- `search issues "repo:ZSeanYves/gh_test"` 返回这三个关闭 Issue。实现会补充 GitHub API 要求的 `is:issue` qualifier；没有这个 qualifier 时 GitHub 返回 422。
- `search repos gh_test --json nameWithOwner` 返回了多个公共仓库，说明全站搜索结果 envelope 已展开，但没有证明固定 oracle 的字段兼容。`gh v2.102.0` 的字段名是 `fullName`，`nameWithOwner` 不在该命令的 JSON 字段列表中；下一轮改用 `--json fullName` 和 `gh_test in:name user:ZSeanYves`，限定仓库名及所有者，避免将全站搜索排名当作固定结果。

Issue 分页已单独完成一次稳定字段对照：`GET /repos/ZSeanYves/gh_test/issues?state=all&per_page=2` 在项目 CLI 中返回 2 页、3 条记录（#1–#3），与 `gh v2.102.0` 的归一化 `{number,title}` 数组比较无 diff。该结果只证明这个 REST 分页场景；不能外推到 GraphQL cursor 或其它业务列表。

下一优先级是让扩展后的 runner 对 `repo view`、issue/pr/release/run/workflow 列表和限定 search 结果执行严格的内存 JSON 对照。原始 API smoke 继续使用其明确的 schema 归一化；新增业务 case 比较请求的每一个字段值、枚举大小写、数字类型、数组顺序以及 null/缺失区别，不把差异转成小写或只比较数量。JSON 对象的键顺序和空白格式不参与语义比较，未请求的动态 headers 不参与业务 JSON 比较。通过这个只读矩阵后，再做单个 Issue 的 create/edit/close 生命周期；`gh issue create` 和 `gh issue close` 在 v2.102.0 没有 `--json` 选项，写操作结果应通过 URL 或后续 `issue view --json ...` 验证，避免把不属于 oracle 的 argv 当作兼容证据。

### 20 项 oracle 的首次运行与 workflow 修复

报告 `_build/live-github-business-oracle-20261017-1.json` 记录前 17 项通过；第 18 项 `workflow-list` 失败并停止，因此两个 search probe 尚未执行。项目返回 `[]\n`（3 个字符），oracle 返回空 stdout（0 个字符），双方 exit code 都为 0，stderr 都为空。旧 runner 把 oracle 的空输出判成 `invalid_json`，但项目输出本身也与固定 oracle 不同，不能只放宽 JSON 校验。

已核对固定 tag `v2.102.0`（`fc4b137cdef0a6bd28fd461b7cf9c84a5812a8cd`）的 `pkg/cmd/workflow/list/list.go`：先按 `--all` 过滤非 active workflow，无结果时返回 `NewNoResultsError`，早于 exporter。这解释了管道空输出；移除 `--all` 无法修复空仓库的差异。项目已补充相应的过滤和空结果分支，以及 JSON/jq/template、`--all`、HTTP 403 和 raw API 不受影响的回归测试。runner 保留 20 项，workflow probe 使用 `--limit 10`，并比较空输出种类而不将它转成 `[]`。

随后 `_build/live-github-business-oracle-20261017-2.json` 确认该 workflow 空结果分支通过真实 oracle：双方 exit code 0、空 stdout、空 stderr，`empty_stdout_matches=true`。该证据覆盖捕获 stdout 的管道场景，不代表 TTY 的 `no workflows found` 提示、重复布尔 flag 的顺序或 workflow 完整文本输出已经通过 oracle。

### 第二轮 search-repos 参数边界修复

报告 `_build/live-github-business-oracle-20261017-2.json` 记录前 19 项通过；`search-issues` 的三条记录通过所选字段对照。最后的 `search-repos` 仍有差异：项目返回 1 条、35 字符，oracle 返回 3 条、119 字符，退出码和 stderr 均相同。根因是 v2.102.0 的 `pkg/search/query.go` 会逐个格式化位置参数：含空格、双引号、tab、CR 或 LF 的值会被加引号；含冒号的参数只在第一个冒号后对值加引号。项目此前直接拼接原始位置参数，导致 `gh_test in:name user:ZSeanYves` 产生了不同的 `q`。

原 runner 将整段查询放入单个 argv，原版实际构造 `gh_test in:"name user:ZSeanYves"`，所以 `user:` 不再独立限制 owner。runner 现将 `gh_test`、`in:name`、`user:ZSeanYves` 作为三个参数传入双方，并增加精确 argv 自检；`fullName` 必须属于白名单仓库，否则记录 `response_outside_repository_scope`。这不是归一化掉不同结果，而是修正测试意图与 argv 的对应关系。

项目也修正了搜索位置参数与 flag qualifier 的 quoting，新增 11 组请求 seam 回归覆盖分离参数、完整单参数、短语、冒号值、引号/反斜杠、tab/LF 和 qualifier flag，同时确认 `--limit` 映射到 `per_page`。这只改变 search 的 `q` 构造，不改变 raw `gh api` 输入；不据此宣称全部高级搜索语法或 Go 字符串转义边界已兼容。随后重新构建 Native CLI，并使用新的 `-3.json` 报告重跑了 20 项 oracle。

第三轮报告 `_build/live-github-business-oracle-20261017-3.json` 已完成：20/20 probes 通过，项目和固定 `gh v2.102.0` 的 exit code、稳定 JSON 结果和业务字段对照一致，workflow 空 stdout 也一致；项目的 20 条 trace 均通过脱敏和单请求校验。报告的 `live_server_verified=true`、`oracle_executed=true`，说明这次真实 GitHub.com 网络 smoke 已执行。`core_parity_verified=false` 仍是刻意保留的状态，因为该 runner 只覆盖只读矩阵，不代表写操作、OAuth、keyring、多账户、完整分页或交互集成已经完成。

## 测试顺序

先执行只读探针，确认认证和 URL，再执行需要写权限的场景：

```text
GET /user
GET /repos/<owner>/<repo>
GET /repos/<owner>/<repo>/issues
GET /repos/<owner>/<repo>/pulls
GET /repos/<owner>/<repo>/actions/runs
GraphQL viewer
GraphQL repository(owner: ..., name: ...)
```

当前 smoke runner 比较 exit code、显式 `--include` 输出中的 HTTP status、响应结构、固定身份，以及脱敏 trace 中的 method/path/请求次数；可选地与固定版本 oracle 比较 JSON 输出。业务 JSON probe 在内存中严格比较所选字段和空集合语义，不把完整响应 body 写入报告。它包含 `--jq` 与 `--template` 探针。没有明确分页 probe 时，不能验证分页请求数或 cursor；不保存原始 stdout/stderr，也就不能声称完整字节级输出一致。时间、ETag 和 rate-limit 等动态数据不宜直接作为长期 golden 文本；同一资源的稳定 ID、状态和值仍可在当次项目与 oracle 对照中严格比较。

写测试只能使用专门的临时仓库或测试组织。每个资源带有随机 marker，例如 `codex-live-20261016-<random>`；创建 issue、branch、PR、release/tag 或 artifact 后，无论测试成功还是失败都必须执行清理。清理逻辑用 `errdefer` 或等价的 finally 语义，并且不能删除 marker 之外的业务数据。

## 与 v2.102.0 的差分

同一组 argv 依次运行本项目 Native CLI 和本地校验过 SHA-256 的 `gh v2.102.0`。仓库 view probe 使用位置参数 `repo view ZSeanYves/gh_test`，因为 v2.102.0 的 `repo view --help` 没有继承 `-R/--repo`；业务命令的 `-R` 只在其自身支持时使用。差分只比较稳定的行为：

- exit code，以及 stdout/stderr 的分离；
- method、规范化 path/query 和分页请求次数；
- status、错误类别和稳定的 JSON schema；
- `--json`、`--jq`、`--template`、`--include`、`--silent`、`--verbose` 的输出策略；
- trace 字段和脱敏结果。

验收报告可以只保存 method、path、status、必要的响应头、脱敏后 body 的哈希和 schema 名称：

```json
{
  "method": "GET",
  "path": "/repos/<owner>/<repo>",
  "status": 200,
  "headers": { "content-type": "application/json" },
  "body_sha256": "...",
  "schema": "repository"
}
```

上述元数据报告不能直接重放。需要 cassette 时，另存经审查的脱敏响应 body 和必要 headers，保留类型、字段关联和分页结构。不得保存 `Authorization`、token、完整私有内容或可识别的业务数据。经审查的 cassette 才能重放到 loopback fixture server；仅当真实网络案例确实执行且通过时，报告才标记 `live_server_verified=true`。

固定 oracle 的本机可执行文件及哈希示例：

```text
GH_ORACLE_BINARY="$HOME/.local/opt/gh-v2.102.0/gh_2.102.0_linux_amd64/bin/gh"
GH_ORACLE_SHA256=7469124f706944133d6a169691dd1c6c3511b12e85878d255e044e2948df4c9b
```

在已经持有 `GH_TOKEN` 的同一个本机 shell 中运行以下命令。报告文件必须是新路径；已有同名报告时改用新的后缀，runner 不覆盖旧证据。本次 agent 进程没有继承该 shell 的 token，因此准备和 self-test 不代表修复后的真实网络对照已执行。

```bash
LIVE_GITHUB=1 GH_LIVE_REPO=ZSeanYves/gh_test \
GH_ORACLE_BINARY="$HOME/.local/opt/gh-v2.102.0/gh_2.102.0_linux_amd64/bin/gh" \
GH_ORACLE_SHA256=7469124f706944133d6a169691dd1c6c3511b12e85878d255e044e2948df4c9b \
moon run --target native scripts/live_github_fixture.mbtx -- \
  _build/native/debug/build/cmd/main/main.exe \
  _build/live-github-business-oracle-20261017-3.json
```

哈希必须针对实际传给 runner 的 `bin/gh` 文件执行 `sha256sum`，不能用 tarball 哈希代替；runner 仍会检查版本前缀 `gh version 2.102.0`。上述固定摘要来自已记录的 [oracle provenance](oracle-status.md#executable-provenance)，本机安装的 binary 已核对一致；该记录也明确说明来源校验和一致性不等于独立签名或 attestation 验证。不要把未经验证文件刚算出的哈希直接当作可信基准。

## Enterprise

Enterprise 测试使用独立的临时配置、Enterprise token 和 `GH_HOST`，验证 REST `/api/v3` 与 GraphQL `/api/graphql` 的 URL 选择。不要把 Enterprise 凭据混入 GitHub.com 测试，也不要把真实 hosts.yml 或 keyring 数据复制到工作区。

`scripts/gh_oracle.mbtx` 仍是原版 CLI help/oracle corpus 工具，不会自动连接 GitHub.com；`docs/compat/oracle-status.md` 的 `network_fixture_executed: false` 指该固定 corpus 没有真实账户网络记录，仍然准确。此 live runner 的一次本地执行应单独记录报告路径和是否运行成功。
