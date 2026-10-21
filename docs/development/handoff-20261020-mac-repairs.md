# Mac 缺陷修复与真实差分（2026-10-20）

后续 OAuth/Keychain 和此前待权限的 deploy key 成功验收见
[2026-10-21 记录](handoff-20261021-oauth.md)。本文保留当时的 binary 和结果。

## 范围

本轮在 `master`、基线 `c1b8712ab01fa9debd5d8d4bdba643371bb5bd15`
上修正 2026-10-19 交接中明确列出的错误路由和语义问题，并修正真实差分
发现的 Issue/PR 混合列表问题。固定 oracle 为 GitHub CLI v2.102.0。
所有线上写入限定在已授权的 `ZSeanYves/gh_test`。

`core_parity_verified=false`。本轮不改变旧交接中尚未实现的功能列表；
229 个 help 快照仍然不是逐命令兼容验收。

最终二进制 SHA-256：
`b908bd783052051ab9e7786ebe3cffb60bb973eadbcdf349876a2594cf21d7e3`。
Oracle 为官方 macOS arm64 release，archive SHA-256 与官方 checksum 清单
一致：`da922c20d1792e5b2cbf375593d7a658acf034c12c84e007e71c76ef959c337e`；
解包后二进制为
`8a4258433c81106343144857750316241759d06dcf16265cf3c4864a8f2f2ad6`。
未另行做签名/attestation 验证。

## 最终结果

| 门禁 | 结果 | 证据 |
| --- | --- | --- |
| 最终 binary 只读差分 | 20 passed / 0 failed | [live-read.json](../compat/mac-20261020/live-read.json) |
| 修复项真实验收与差分 | 28 passed / 2 pending permission / 0 failed | [live-repair.json](../compat/mac-20261020/live-repair.json) |
| 既有写生命周期回归 | 59 passed / 10 skipped / 0 failed | [live-write.json](../compat/mac-20261020/live-write.json) |
| 干净源码四 target | Native 272、Wasm 68、Wasm-GC 51、JS 68，全部通过 | [clean-gate.log](../compat/mac-20261020/clean-gate.log) |
| 接口、格式、runner | `.mbti` 无变化；格式检查和三套 runner 离线自测通过 | [汇总](../compat/mac-20261020/summary.json) |

两套真实写测试均 `cleanup_passed=true`，无活动残留。10 个既有 skip 为：
null description 的仓库编辑、workflow dispatch、run view/logs/artifacts/
cancel/rerun/watch/exit-status、cache 创建。它们没有被改记成通过。

干净副本先确认直接 frozen 检查因未安装依赖而退出 255；运行非 frozen
check 安装固定依赖后，frozen check/tests 全部通过。这是 CI 安装顺序
修复的本机复现证据，尚未推送触发新的 Linux/macOS/Windows hosted CI。

汇总记录基线提交、当前未提交状态、工具链、二进制/oracle hash 和
[源码 hash 清单](../compat/mac-20261020/tested-source-sha256.json)。
源码和保留报告已检查，不含本次测试 token。改动仍在本地，未提交或推送。

## 修复

- `pr checks` 先解析 PR node，读取最新提交的 CheckRun 和 StatusContext，
  分页、去重并按上游 bucket 输出；普通输出区分失败 1、等待 8、成功 0，
  JSON exporter 按上游返回 0。空集合保留上游错误文本。
- `pr status` 改为当前分支、本人创建、等待本人 review 的聚合；
  `issue status` 改为 assigned、mentioned、createdBy 三组。
  无当前 PR 时省略 JSON `currentBranch`；作者字段遵循上游导出结构。
- `issue pin/unpin/develop`、`pr revert` 使用真实 GraphQL mutation，
  删除猜测的 REST 路由。`develop --base` 保存本地
  `branch.<name>.gh-merge-base`。
- `pr update-branch --rebase` 使用 `updatePullRequestBranch`、
  `expectedHeadOid` 和 `updateMethod: REBASE`；已同步时不写入。
- `repo deploy-key add` 读取位置文件参数或 `-` 标准输入，
  默认 `read_only=true`，只有 `--allow-write` 改为可写。HTTP 权限拒绝
  按业务命令输出到 stderr，不再把原始 API body 写到 stdout。
- `issue list` 在计入 `--limit` 前排除 REST `/issues` 返回的 PR，
  全 PR 页也继续按 Link 分页。
- CI 在 frozen gate 前先安装依赖；补齐 write/repair runner 离线自测。
  只运行 `moon update` 不会填充干净 checkout 的依赖目录。

## 验证方法

只读 runner 比较原有 20 项 API/业务命令。新增
[`live_github_repair_fixture.mbtx`](../../scripts/live_github_repair_fixture.mbtx)
创建带唯一 marker 的 Issue、PR、分支和 commit status，比较 stdout、
stderr 和退出码，再检查真实对象状态。JSON 比较仅忽略对象键顺序及 JSON
空白；数组顺序、类型、大小写、null 与缺字段均保留。

GitHub search 在创建 PR 后存在索引延迟，runner 先用 oracle 确认 marker
PR 已出现在搜索结果中，再进行非空差分；不按 candidate 结果重试筛掉差异。
所有 mutation 之后都执行清理，并检查默认分支 SHA 未变。
已合并/已关闭 PR 和 commit status 历史仍可能可见，清理不声称删除历史。

本轮线上非空状态数据来自本人创建的 Issue/PR；assigned、mentioned、
review-requested 的非空分类另有受控 fixture，不能据此声称多账户线上验收。
真实 checks 状态由 legacy commit status 构造；CheckRun 的分页/去重有
受控测试，真实 Actions workflow/CheckRun 生命周期仍待补。

测试 token 只由本机入口读取并作为子进程环境变量传入，不写入报告、源码
或命令行。报告保存结果及输出 hash，不保存 token 或私钥。

早期差异和中间版本报告保存在
[`mac-20261020-before-denial-fix`](../compat/mac-20261020-before-denial-fix/)；
它们使用旧 binary，不替代最终报告。

## 保留的边界

- Deploy key 成功生命周期需要当前凭据额外授权；本轮真实请求中 candidate
  和 oracle 均被权限拒绝。文件读取和只读/可写 payload 有受控测试；
  权限拒绝的输出差分单独计数，不代表成功创建/回读/删除已经验收。
- OAuth device/web consent、系统 Keychain、多账户切换需要测试 OAuth App
  和用户参与；组织/environment、Enterprise 和 Windows/Linux 主机验收
  仍依赖相应环境。
- 状态输出的完整 TTY、所有 JSON 字段、检查/review 摘要、fork/remote
  分支解析、`issue develop --checkout/--worktree` 以及完整 `--watch`
  交互不在本轮线上通过范围。
- Actions run 日志/ZIP 下载、完整 formatter、Projects/Discussion、
  completion 等未实现项继续按
  [2026-10-19 交接](handoff-20261019-mac.md) 排期。
- 本机通过不等于 hosted CI 已通过。需要推送当前改动后读取新的三平台
  CI 结果；不能沿用旧提交或 Linux binary 的报告。
