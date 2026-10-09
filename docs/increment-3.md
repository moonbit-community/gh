# Increment 3：条件写入、评论与异步合并

本增量完成客户端的七个写操作，继续使用独立 `/api/v1` 契约和本地 HTTP
fixture。没有修改 MoonHub 服务端，没有向真实账户写入数据。服务端作者仍需
确认并实现[写 API 契约](mutation-api-contract.md)，才能验收真实权限及合并行为。

## 命令与输入

`gh` 表示 Native 构建产物 `_build/native/release/build/cmd/main/main.exe`，也可以
用 `moon run cmd/main --` 运行。host、token、仓库、JSON 和 trace 选项沿用
[Increment 2](increment-2.md)。所有写命令均非交互式。

| 命令 | 必填参数 | If-Match |
| --- | --- | --- |
| `issue create` | `--title TEXT` | 不需要 |
| `issue comment NUMBER` | `--body TEXT` 或 `--body-file PATH` | 不需要 |
| `issue close NUMBER` | `--if-match TAG` | 必须 |
| `issue reopen NUMBER` | `--if-match TAG` | 必须 |
| `pr create` | `--title TEXT --source BRANCH --target BRANCH` | 不需要 |
| `pr comment NUMBER` | 正文及 `--if-match TAG` | 必须 |
| `pr merge NUMBER` | `--if-match TAG` | 必须 |

两个 create 命令可选 `--body` / `--body-file`；未提供则 description 为空。
`pr create` 可选 `--draft`。`--source` 和 `--target` 是同一仓库内的分支，
由服务端校验存在性、比较版本及合并策略。

```sh
gh issue create --host https://moonhub.example -R team/demo --title '完善文档' --body-file issue.md --json
gh issue comment 7 --host https://moonhub.example -R team/demo --body '补充说明' --json
gh pr create --host https://moonhub.example -R team/demo --title '更新文档' --source docs/api --target main --draft --body-file mr.md --json
```

这些是面向已实现契约的服务器的使用示例，域名是占位符。`--body-file -` 从
stdin 读到 EOF，不启动编辑器，也不显示输入提示。文件/stdin 最多读取 80,000
字节，超时 30 秒，严格 UTF-8 解码；文件必须是普通文件。SDK 再执行领域限制：
title trim 后 1–200 个 UTF-16 code unit，description/comment 最多 20,000；
评论不能为空白。正文保留换行和 Unicode，不做 trim。两种正文来源不能并用。
文件路径、解码异常、正文和 token 不进入错误文本或 trace。

## ETag 的读取和使用

先用 `issue view NUMBER --json` 或 `pr view NUMBER --json` 查看资源。
单资源读取结果现在包含顶层 `etag`，值为服务端强 ETag 原文或 `null`。例如：

```json
{"version":1,"data":{"number":7},"pagination":null,"etag":"\"copied-server-tag\""}
```

示例 data 为简写；实际仍输出完整 DTO。用户或 AI 检查资源后，把包括双引号
在内的标签作为单个参数传回：

```sh
gh issue close 7 --host https://moonhub.example -R team/demo --if-match '"copied-server-tag"' --json
gh pr merge 3 --host https://moonhub.example -R team/demo --if-match '"copied-mr-tag"' --json
```

标签来自对应资源最近读取的响应，不是从编号或 edit_version 拼接的模板。
客户端接受一个最多 256 ASCII 字符的强引用标签，拒绝弱标签、通配符、多个
标签及控制字符。缺少必需 `--if-match` 时不发送请求；不会在后台重新 GET
最新标签来绕过冲突。收到 412 后，重新读取、检查变化，再决定是否继续。
返回错误资源编号或仓库身份的读取也会被拒绝，并清除其 ETag。

Issue comment 是独立追加活动；MR comment 绑定当前 revision 比较版本，
所以两种评论的 If-Match 要求不同。这来自 MoonHub 已有领域模型。

## 写入结果与退出码

普通写成功输出：

```json
{"version":1,"data":{"number":7,"kind":"commented"},"pagination":null,"etag":null,"outcome":"applied"}
```

Merge 是异步任务。202 成功输出仅确认受理：

```json
{"version":1,"data":{"number":3,"version":"1","job_status":"pending"},"pagination":null,"etag":null,"outcome":"accepted"}
```

两者退出码都是 0，但 `accepted` 不代表已经合并。后续用 `pr view --json`
查看 `status`、`merged_sha` 和新增的可空 `job_status`。后者取值为 pending、
running、succeeded、failed；客户端不自动轮询，也不透传原始 job_error。

写失败的 stderr 继续使用既有 error envelope，并在 error 内增加 outcome：

```json
{"version":1,"error":{"code":"conflict","message":"resource conflict or stale version","status":412,"request_id":null,"outcome":"rejected"}}
```

| outcome | 含义和后续行为 |
| --- | --- |
| `not_sent` | 本地参数/配置/正文输入失败，没有 HTTP 尝试 |
| `rejected` | 服务端以 4xx 明确拒绝；修正权限或重新读取冲突资源后再决定 |
| `applied` | 预期状态、响应数据及必要 ETag 均验证成功 |
| `accepted` | 异步合并已受理，仍需观察最终结果 |
| `unknown` | 发送已尝试，但不能确认远端结果；先检查资源/服务端历史 |

断连、5xx、重定向、意外成功状态、成功正文解码失败或缺少必需 ETag 都可能
发生在服务端已经提交写入之后，因此归为 unknown。**不会自动重试任何写操作**，
包括 create/comment。当前不提供幂等键或“恰好执行一次”的保证。
创建响应必须处于 open，MR 还须对应指定的 source/target/draft；已知目标的
响应编号及关闭/重开状态也必须匹配。违约的成功响应不能被报告为 applied。

退出码沿用 0 成功、1 HTTP/协议失败、2 本地非法输入、3 身份/权限、4 冲突、
5 transport。解析器尚未生成命令计划时，参数错误保留既有 JSON 格式；不附加
写 outcome。进程中断和 stdout/stderr 写入失败也可能无法产生完整 JSON，
不能从退出码本身推断写入已回滚。SDK 取消语义沿用 Increment 1，继续向外传播。

trace 仍只记录每个真实 HTTP 尝试的元数据，不含 ETag、正文或 token。写入后
trace 失败会追加 stderr warning，保留 applied/accepted 和原退出码；协议解码
发生在 HTTP trace 完成之后，不重写或复制 trace。JSON stderr 继续按 JSONL 读取。

## 代码与复用

- `moonhub/etag.mbt`：强 ETag 值对象及响应头校验。
- `moonhub/mutations.mbt`、`mutation_models.mbt`：七个类型化操作、receipt 和 outcome。
- `moonhub/operations.mbt`、`paging.mbt`：读取 ETag 及单资源身份校验。
- `cli/`：复用 core/argparse，提供参数计划、确定性 JSON、人类输出和退出码。
- `native/body.mbt`：复用 async/fs、io、stdio 和 core/buffer、UTF-8 解码读取正文。

依赖版本保持 `moonbitlang/async@0.21.3`、`moonbitlang/x@0.5.5`；本增量没有新增
外部依赖、项目 FFI、HTTP 栈或参数解析器。公开具体类型仍由公共 facade 拥有，
没有导入 MoonHub 的数据库/Web 包。

## 验证和服务端交接

本地 macOS / Moon `0.1.20260920` 验证：**82/82 Native 测试、14 组读取场景、
14 组写入场景通过**；全部目标类型检查和 Native release 构建通过。全部目标
类型检查不代表其他平台已经完成运行验收。

```sh
moon check --deny-warn
moon check --target all --deny-warn
moon test --target native --strip -j 1
moon build --target native --release --deny-warn
moon run --target native scripts/read_smoke.mbtx
moon run --target native scripts/mutation_smoke.mbtx
moon info
moon fmt . scripts/read_smoke.mbtx scripts/mutation_smoke.mbtx
```

写操作脚本启动 loopback HTTP fixture，运行真实可执行文件，验证七个 POST、
GET ETag 到 If-Match 的原样传递、UTF-8 文件/stdin、权限/冲突、已收正文后的
断连、坏成功响应、trace 失败与脱敏。报告保存到 `_build/increment-3-smoke.json`，
临时输入和 trace 文件自动清理。此前读取脚本继续执行，检查只读路径回归。
条件写入场景使用同一服务和资源完成读取、关闭、旧标签重开得到 412、再次读取
确认状态保持关闭；客户端没有偷偷刷新标签或重试。

服务端交接材料为 `docs/mutation-api-contract.md` 和 `testdata/mutations/`。
需要服务端实现的核心是 Bearer 权限、稳定错误类别、完整表示的强 ETag、原子
If-Match 校验与现有 merge worker 的安全检查。客户端验证了如何处理权限拒绝，
并未证明真实服务端权限已经实现。下一增量仍是 pipeline 与 trace 查询等运维工具。
