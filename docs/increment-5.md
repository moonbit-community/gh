# Increment 5：通用 JSON API 入口

本轮补齐架构书首版范围中的通用 `api` 命令。原来的增量清单只列到 Increment 4，
没有分配这项已明确要求的能力；现在将其落实为 Increment 5，并保留原有分层。
MoonHub 服务端实现和真实服务器联调仍是独立验收事项。

## 命令与 SDK

```sh
moon run cmd/main -- api /meta --host https://moonhub.example --json
moon run cmd/main -- api '/repos/team/demo/issues?page=1&per_page=30' --host https://moonhub.example --json
moon run cmd/main -- api /repos/team/demo/issues -X POST --input issue.json --host https://moonhub.example --json
moon run cmd/main -- api /repos/team/demo/issues/7/close -X POST --input close.json -H 'If-Match: "tag-from-view"' --host https://moonhub.example --json
```

`--input -` 从 stdin 读取一个完整 JSON 值；没有 `--input` 就不提供请求体，
与文件内容为 `null` 不同。默认方法固定为 GET，提供 input 不会隐式改成 POST。
支持 GET、POST、PUT、PATCH、DELETE；GET 不接受 input。
上例 `issue.json` 按创建 Issue 契约提供 title/description，`close.json` 内容为 `{}`。

路径必须以 `/` 开头，相对于 `/api/v1`，例如 `/meta`。拒绝绝对 URL、越界路径和
重复的 `/api/v1` 前缀；query 按原文发送，trace 不记录 query。`--repo` 不适用于
显式 API 路径，环境变量 `MOONHUB_REPO` 也不会改写路径。

SDK 入口为 `moonhub.Client::api(Request, operation_id~)`。公共
`validate_api_request` 供 CLI 和 SDK 共用；`ApiResponse`、`ApiResult` 位于
`moonhub/`。它们复用根包 Request/Transport/ApiFailure/TraceRecord，不依赖
MoonHub 数据库或 Web 包。Native 组合仍使用现有输入读取器、鉴权、HTTP 和 trace。

## 输入与响应契约

输入沿用 80,000 UTF-8 字节、30 秒超时和普通文件／stdin 读取边界。JSON 校验后
发送原文，不把大整数、空白或转义先解析再重新编码。SDK 直接调用也检查同样的
字节限制。这里没有 Issue/MR 文本字段的 20,000 UTF-16 单元上限；各具体端点仍
需自行执行领域字段约束。

`-H/--header 'Name: value'` 可重复用于不同请求头。客户端保留鉴权、目标 origin、
HTTP framing 和方法控制；自定义 header 不允许替换这些信息。共享校验限制字段
数量、长度、ASCII 编码和重复名称，固定 JSON Accept/Content-Type、identity
编码，并在出现 If-Match 时要求单个强 ETag。完整列表见
[API 命令契约](api-command-contract.md)。

Generic 成功响应保留**整个 JSON 值**，不假定服务器 envelope 版本，也不进行
领域 DTO 字段筛选。204/205 仅接受空正文并映射为 null；其余 2xx 必须包含合法
JSON，包括显式 JSON null、标量或数组。JSON 输出结构为：

```json
{
  "version": 1,
  "data": { "version": 7, "data": { "custom": true } },
  "status": 200,
  "request_id": "server-request-id",
  "etag": null,
  "outcome": null
}
```

外层 version 是 CLI 协议，内层 data 是完整服务器数据。响应是解析后的 JSON，
输出会规范化格式，不保证原始响应字节一致。当前 core JSON 会保存数字原文表示；
大整数 stringify 已有 SDK 测试。将其转换为 Double 运算仍受浮点精度限制。
不打印任意响应头；仅输出安全 request ID 和合法强 ETag。

人类模式 stdout 是完整 pretty JSON；写操作的 HTTP 状态和 outcome 写入 stderr。
请求得到的正常正文可能含敏感业务字段，这是调用者明确请求的数据。错误诊断和
trace 继续只包含固定文本／元数据，不回显失败响应、正文、token 或自定义头值。

## 执行与结果

所有 generic 请求都只发送一次，包括 GET；不继承类型化 GET 的自动重试，也不
跟随重定向、自动分页、预检或刷新 ETag。显式 `--max-attempts` 仅接受 1。
已封装的领域命令保留原有 DTO 校验和读重试策略。

非 GET 请求沿用 `not_sent / rejected / applied / accepted / unknown`：

- 已解析命令的本地配置、文件或 JSON 校验失败：`not_sent`。
- HTTP 4xx：`rejected`；退出码继续区分鉴权、冲突和其他错误。
- 合法 202：`accepted`；其他合法 2xx：`applied`。
- 网络异常、5xx、重定向、坏 JSON 或无效成功 ETag：`unknown`。

纯参数语法错误沿用既有错误结构，不从未成功解析的 argv 推测 outcome。
`applied` 表示服务器按 HTTP 协议确认操作成功，不验证领域字段，也不代表异步
任务已完成。`accepted` 后应查询对应端点；`unknown` 后先核实结果，不能盲目重发。
Trace 写入失败不会改变 HTTP 结果或触发重试。

Conditional header 必须由调用者根据端点契约显式提供；通用入口不会自动猜测
哪些 URL 要求 If-Match。服务端仍需执行权限与并发约束，不能依赖客户端校验。

## 复用与验收

继续使用 core argparse/JSON/UTF-8，以及已固定版本的 async HTTP、TLS、文件、
stdin、超时和 subprocess。没有新增外部依赖、项目 FFI 或系统 HTTP 工具。
没有新增独立的 JSON 解析器、凭据存储或输入读取器。

SDK 测试覆盖输入边界、原文发送、header/path 拒绝、完整 JSON 返回、204/205、
单次发送、写入歧义、敏感信息和 trace 失败。CLI 测试覆盖命令计划、稳定输出和
stdin 解析职责。

`scripts/api_smoke.mbtx` 启动真实 release 二进制，用本地 HTTP fixture 验证五种
方法、原始文件／stdin 输入、强 ETag、自定义头、错误退出码、JSON null、写入结果、
单次请求、不跟随重定向和落盘 trace。输入异常用关闭的 loopback origin 验证在
网络前失败；不接触真实账户。报告输出到 `_build/increment-5-smoke.json`。
运行命令见 [release.md](release.md)，固定数据位于 `testdata/api/`。

本地已通过 **123/123 项 Native 测试**、**18 组 Increment 5 可执行文件场景**，
另有 **48 组既有 CLI 回归场景**（read 14、mutation 14、operations 20）全部通过，
无警告的 Native release 构建和全目标类型检查通过。类型检查不等同于各平台
运行时验收。环境沿用 macOS arm64 与 `moon 0.1.20260920`。

HEAD/OPTIONS、multipart、二进制上传下载、流式响应、jq/template、交互式认证、
自动重放和通用分页不在本增量范围。当前本地 fixture 证据也不等价于真实 MoonHub
API、Linux/Windows 运行时或生产发布验收。
