# Increment 2：只读 SDK 与 Native CLI

> 历史报告：保留当时的实现范围、限制和验收数字，不代表当前使用说明。
> 当前行为、命令和平台边界见[文档索引](../README.md)。

本增量完成客户端和本地契约 fixture：`/meta`、当前用户、仓库 list/view、
Issue list/view、Merge Request list/view，以及版本化 JSON、分页和退出码。
MoonHub 源码仍没有公开的 `/api/v1`，因此这里的结果是**客户端契约验收**，
不是已经与真实 MoonHub 服务端完成对接。

后续 [Increment 3](increment-3.md) 在读取 JSON 中追加 `etag`，并为 MR 数据追加
可空的 `job_status`，供条件写入和异步合并查询使用。下面保留 Increment 2 的
验收记录；新增字段和写操作以 Increment 3 文档为准。
后续 [Increment 4](increment-4.md) 已加入 pipeline、离线 trace 查询和有界读重试；
本文的“无自动重试”和“后续计划”描述仅指 Increment 2 当时的实现。

## 运行与命令

```sh
moon run cmd/main -- --help
moon build --target native --release --deny-warn
```

构建产物是 `_build/native/release/build/cmd/main/main.exe`。下文用 `gh`
表示这个可执行文件；也可以用 `moon run cmd/main --` 代替。

| 命令 | 行为 |
| --- | --- |
| `gh meta` | 查询 API 版本、服务端版本和 capability 列表 |
| `gh auth status` | 查询当前身份；不打印 token、不签发凭据 |
| `gh repo list` | 查询当前身份可见的仓库，过滤由服务端负责 |
| `gh repo view [OWNER/NAME]` | 查询指定仓库 |
| `gh issue list` / `gh issue view NUMBER` | 查询指定仓库的 Issue |
| `gh pr list` / `gh pr view NUMBER` | 查询指定仓库的 Merge Request |

```sh
gh meta --host https://moonhub.example --json
gh auth status --host https://moonhub.example --config /trusted/hosts.json --json
gh repo view team/demo --host https://moonhub.example --json
gh issue list --host https://moonhub.example -R team/demo --json
gh pr list --host https://moonhub.example -R team/demo --paginate --json
gh issue view 7 --host https://moonhub.example -R team/demo --trace /trusted/trace.jsonl
```

示例域名是占位符，需要实现了[读 API 契约](../contracts/read-api.md)的服务器。
当前 MoonHub 的浏览器页面不能作为这些命令的 API。

配置优先级：

- origin：`--host` > `MOONHUB_HOST`；没有隐含 GitHub 或默认服务器。
- 仓库：`repo view OWNER/NAME` 或 `--repo/-R` > `MOONHUB_REPO`；两种显式
  仓库不一致时拒绝。尚未实现从本地 Git remote 自动发现仓库。
- CLI token：`MOONHUB_TOKEN` > `--config PATH` 指定的 v1 hosts JSON；格式和
  origin 绑定沿用 [Increment 1](increment-1.md)。CLI 不接受 token argv。
- `--trace PATH` 才落盘；目录需已存在并可信。不写入 stdout，不创建凭据文件。

`--repo` 和 `MOONHUB_REPO` 只用于需要单仓库上下文的命令；`repo list`
始终列出服务端允许当前身份访问的仓库。`meta` 不会被隐式加到其他命令前，
capability 目前是查询信息，不是每次请求的预检门槛。

## JSON、错误与退出码

`--json` 是布尔开关，不接受 GitHub CLI 的字段选择表达式。成功时 stdout
输出一个紧凑 JSON 对象和换行，字段顺序固定：

```json
{"version":1,"data":[],"pagination":{"pages":1,"next":null}}
```

单对象操作的 `pagination` 为 `null`；列表的 `pages` 是本次读取的页数，
`next` 是验证后的 SDK 相对路径（省略 `/api/v1`）或 `null`。它表示是否还有
下一页，不是快照一致性承诺。DTO 可选字段输出标量或 `null`，不会出现
MoonBit Option 的 `[]` / `[value]` 编码。ID 和版本使用十进制字符串，
Issue/MR number 暂限定正 Int32。完整字段定义见[契约](../contracts/read-api.md)。

失败时 stdout 为空，stderr 输出：

```json
{"version":1,"error":{"code":"forbidden","message":"permission denied","status":403,"request_id":null}}
```

错误文本是客户端固定文案，不透传服务端正文、异常详情或错误 argv。
trace 写入失败不会改变已有 HTTP 结果；stderr 另加 `warning.code=trace_failed`
的 JSON 行。因此 JSON 模式的 stderr 应按 JSONL 消费，可能包含 error 和 warning
两行。正常数据只出现在 stdout。人类模式用简洁行输出，并清理服务端文本中的
控制字符；描述全文保留在所请求的 JSON 数据中。

| 退出码 | 意义 |
| --- | --- |
| 0 | 成功，包括仅 trace 写入失败 |
| 1 | HTTP/服务端/协议解码失败；例如 404、429、500、重定向、非法 next |
| 2 | 命令、参数或本地配置非法；请求未发出 |
| 3 | 401 或 403 |
| 4 | 409 或 412 |
| 5 | transport 未完成 |

HTTP 400/422 是远端命令失败（1），本地参数非法是 2。stdout/stderr 自身写入
失败或进程中断使用 1，无法保证此时还能输出完整 JSON；调用者须检查退出码。

## 分页与 trace

列表默认只请求 `page=1&per_page=30`。列表专属参数：

- `--page N`：1–1,000,000。
- `--per-page N`：1–100。
- `--paginate`：从指定页开始按 next 顺序聚合。
- `--max-pages N`：默认 20，可设 1–100；总条数固定最多 1,000。

只跟随同源、同路径且 page 恰好加一、per_page 不变的 next。两个参数都必须
存在且是规范正整数；拒绝额外/重复 query、重复 next、anchor、跨源或跨资源跳转。
支持同源绝对 URL、`/api/v1/...`、`?page=...` 和同目录相对链接。
Link 限制 64 KiB ASCII；没有 next 时结束，不根据页长度猜测。
即使没有 `--paginate`，也验证返回的 next。

达到上限但还有更多页、后续页 HTTP 失败或任意资源格式非法时，返回明确失败，
不输出部分成功数组。服务端在两次请求间的数据变化可能导致 offset 分页重复或遗漏；
本增量不提供跨页事务快照、去重或无限抓取。请求没有自动重试。

一次命令生成一个 operation ID，每个实际 HTTP 请求递增 attempt。trace 记录
HTTP 完成结果，随后发生的 DTO/分页解码错误由 `ReadResult` / CLI 返回，
不会重复写入第二条请求 trace。正文、token 和 query 不写入 trace。

## 实现与依赖

- `moonhub/resources.mbt`：公共 DTO、标准 FromJson 解码与确定性序列化。
- `moonhub/operations.mbt`：八个类型化读操作；`paging.mbt` 负责有界请求编排。
- `internal/pagination`：MoonHub 的有限 Link 策略，不是通用 URI/RFC 库。
- `cli`：官方 `core/argparse` 解析、纯命令计划、展示和退出码。
- `native/run.mbt`：读取环境、组装 Native SDK 并执行计划。
- `cmd/main`：只处理进程参数、输出和退出。

复用 `moonbitlang/async@0.21.3` 的 HTTP/TLS、异步、文件和进程能力，官方 core
的 JSON、字符串、环境与 argparse；新增 `moonbitlang/x@0.5.5` 仅用于 sys.exit。
版本与已检查的 MoonHub 依赖对齐。项目没有新增 FFI、curl 子进程或手写通用参数
解析器。现有 async/http 未提供 Link 解码器，因此只实现本契约所需的有界规则。

Native transport 的 IPv6、压缩、代理、响应体大小等既有限制沿用 Increment 1。
`moon check --target all` 是类型检查，不代表其他后端完成运行验收。

## 验收与服务端交接

本地 macOS / Moon `0.1.20260920` 验证：**64/64 Native 测试通过，14 组真实
可执行文件契约场景通过**；全部目标类型检查和 Native release 构建通过。

在仓库根目录执行：

```sh
moon check --deny-warn
moon check --target all --deny-warn
moon test --target native --strip -j 1
moon build --target native --release --deny-warn
moon run --target native scripts/read_smoke.mbtx
moon info
moon fmt
```

单元/组件测试覆盖 DTO、fake transport、分页终止/上限/越界、trace 聚合、
参数计划、JSON 输出与退出码。`read_smoke.mbtx` 启动本地 HTTP fixture，运行真实
可执行文件，读取提交在 `testdata/read-api/` 的八类成功响应，验证 Bearer、
分页、落盘 trace、trace 失败、坏响应及错误退出码。
运行报告写入 `_build/increment-2-smoke.json`，临时凭据和 trace 目录自动清理。

交给 MoonHub 作者的具体材料是 `docs/read-api-contract.md` 和
`testdata/read-api/*.json`。作者仍需确认并实现路由、字段、token 权限、可见性过滤
和分页；然后才能用同一 CLI 对真实服务器验收。Mutation、ETag/If-Match、pipeline、
token 签发/撤销和 trace 查询命令继续属于后续计划。
