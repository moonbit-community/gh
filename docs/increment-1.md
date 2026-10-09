# Increment 1：可注入客户端、凭据、错误和 trace

本增量完成 SDK 调用基础；CLI 仍仅显示帮助。MoonHub 服务端的 `/api/v1`
尚未随此增量实现，测试中的协议是客户端提案，不能视作线上联调通过。

## 已实现的调用路径

```text
@native.client(base_url, token/config_path, trace_path)
  -> 凭据优先级与 origin 校验
  -> @moonhub.Client（注入 transport / clock / trace callback）
  -> execute（验证路径/请求头、注入 Bearer、补 /api/v1）
  -> upstream async HTTP（一条连接、一次尝试）
  -> HTTP 状态与 MoonHub v1 错误解码
  -> 脱敏 trace callback -> JSONL 文件
  -> CallResult { response, trace_failed }
```

`@moonhub.Client` 不读取进程环境，也不访问文件。`@native.client` 是运行时
组合入口：读取配置、构造 HTTP 适配器，但在 `execute` 前不建立网络连接。
公共类型归属 root / moonhub；`internal/*` 不会泄漏到 SDK 的公共类型中。

## 使用 SDK

Native 应用导入 `ZSeanYves/gh`、`ZSeanYves/gh/moonhub` 和
`ZSeanYves/gh/native`，示例调用如下（凭据示例为占位值）：

```moonbit
let configured = @native.client(
  base_url="https://moonhub.example",
  config_path="/private/config/moonhub.json",
  trace_path="/private/logs/moonhub.jsonl",
)
match configured {
  Err(error) => println(error.code())
  Ok(client) => {
    let call = client.execute(
      @gh.Request::new(verb=@gh.Get, path="/user"),
      operation_id="operation-001",
    )
    // call.response is Result[Response, ApiFailure].
    // call.trace_failed must be reported separately from the remote outcome.
  }
}
```

代码需放在 async 函数中。`path` 相对 `/api/v1`，例如 `/user`，不要再添加
`/api/v1`。请求支持五种方法、可选 UTF-8 body 与请求头数组。响应保留状态、
原始 UTF-8 body 和请求头查询。此增量不自动解析成功响应的业务 DTO。

测试可以用 `@gh.Transport::new(origin=..., send=...)` 注入异步函数，并向
`Client::new` 注入时钟和 trace 回调；正式环境和 fake transport 共用相同
的认证、错误和脱敏逻辑。自定义 transport 是受信任扩展，必须忠实遵守其
声明的 origin，不能绕过边界向另一个服务发送请求。

## 凭据和配置

优先级固定为：显式 SDK token > `MOONHUB_TOKEN` > 显式配置文件路径。
高优先级存在但为空/无效时返回错误，不回退到其他账户；有高优先级值时不读
低优先级文件。不自动发现默认配置路径、不写 token、不做登录或签发。

```json
{
  "version": 1,
  "hosts": {
    "https://moonhub.example": "example-token",
    "http://127.0.0.1:8080": "local-test-token"
  }
}
```

键为规范化的完整 origin：小写主机名、去掉默认端口和尾部斜杠；非默认端口
参与凭据隔离。不允许 userinfo、路径、query 或 fragment。HTTPS 用于远端，
HTTP 仅供 `localhost` / `127.0.0.1` 开发场景。配置文件最多 64 KiB，应由调用方放在
权限受控的私有目录中；本增量不实现 keychain，也不改变配置文件权限。

Token 是 opaque 类型，没有 Debug/Show/ToJson；只有明确的
`authorization()` 方法为 transport 构造敏感 header。合法 Bearer 字符集
和长度受到约束，换行/空白不能进入 header。SDK 构造时同时校验 token、
client 与 transport 的 origin，避免凭据跨服务混用。

## 错误行为

| 状态/阶段 | SDK 类别 |
| --- | --- |
| 请求路径/保留头/配置错误，400、422 | invalid_request |
| 401 / 403 / 404 | unauthorized / forbidden / not_found |
| 409、412 | conflict |
| 429 | rate_limited |
| 500–599 | server |
| 其他非 2xx，包括 3xx | unexpected_status |
| 连接、超时、编码、响应上限等 transport 异常 | transport |

HTTP 状态决定主类别；合法 v1 envelope 的已知 `error.code` 作为辅助字段。
未知 envelope 版本、HTML 错误页和不合法 JSON 不会把 401/403 误判成一般解析
错误。`X-Request-Id` 优先于 envelope ID；不安全 ID 和包含已知 token 的 ID
被省略。服务端 message、异常文本、原始错误 body 不进入可展示错误信息。

所有请求一次发送，没有自动重试。transport 失败时远端可能已提交 mutation；
不能根据失败响应推断远端未执行。取消信号继续传播，不转成普通 HTTP 错误。

## Trace v1

```json
{"version":1,"operation_id":"operation-001","attempt":1,"method":"GET","path":"/api/v1/user","status":200,"duration_ms":12,"request_id":"request-001","error_code":null}
```

- 每次实际发送记录一条完成事件；输入校验失败不产生发送事件。
- `operation_id` 与正整数 `attempt` 由调用方提供，为后续分页/重试保留关联。
- query 和 fragment 全部丢弃；编码路径保守隐藏；已知 token 从路径和 ID 中脱敏。
- ID 只允许最多 128 个 ASCII 字母数字及 `._-`；异常文本变为固定错误类别。
- 不保存 header、正文、代码、响应正文，也不保存 body hash；哈希/大小不是本期必需项。
- 回调前和 JSONL 序列化时都脱敏。可选字段是标量或 `null`，不是数组。
- native 文件 sink 追加 JSONL；POSIX 使用 advisory lock 并请求 `0600` 权限，
  Windows 使用单写者路径（上游 Windows 锁适配器当前返回 `ERROR_ACCESS_DENIED`）；
  不自动建父目录，不把 `-` 解释为 stdout，不接受已存在的符号链接或非普通文件。
- 调用方必须控制父目录。上游缺少 no-follow open/fchmod，故不能宣称防御敌对
  并发换链。Windows ACL 及其他平台权限行为尚未单独验收。

写 trace 失败或超过一秒只设置 `trace_failed=true`，保留成功或失败的 HTTP 结果。
进程崩溃可能没有完成事件或留下半行；文件没有自动轮转/裁剪。它是诊断记录，
不是事务审计日志，不支持自动重放。完成记录阶段在一秒内屏蔽取消，以保留已
取得的 HTTP 结果；transport 期间的取消继续传播。外围任务组仍可能报告自己的
取消，这不代表远端 mutation 已回滚。

## 依赖复用和限制

| 能力 | 实现来源 |
| --- | --- |
| HTTP 请求、TLS、HTTP 编解码、socket、超时和取消 | `moonbitlang/async@0.21.3` |
| 环境变量、JSON、UTF-8、缓冲 | MoonBit core |
| 文件创建、读取、追加、权限和锁 | `moonbitlang/async/fs` |
| origin 约束、token 选择、v1 envelope、trace 脱敏 | 本项目的 MoonHub 客户端策略 |

本仓库没有自写网络栈、TLS、JSON parser 或 FFI；适合的社区库优先复用。
版本选取依据是本地 MoonHub 依赖和当前工具链实测，不声称它是最新版本。
`origin.mbt` 是受限 origin/路径策略，不是通用 URL parser。上游 HTTP 的 URL
分解函数是私有实现，公开 Client 构造又会联网，因此不拿它代替纯配置校验。
当前仅支持 ASCII DNS/IPv4 origin；IPv6 字面量明确拒绝，待上游正确处理 bracket
host 并增加运行证据后再开放。

Native transport 每次尝试新建连接，默认 30 秒整个请求超时、8 MiB 响应上限，
使用系统 TLS 校验，只接受 identity 编码和有效 UTF-8。不跟随重定向、不自动
读取代理环境、不自动重试、不持久化 Cookie。二进制/流式下载、连接池、代理
配置、压缩和自定义证书均未纳入本增量。上游会合并重复响应头，无法恢复原始
重复 header 行。HTTP parser、TLS 和 DNS 的行为由上游负责；8 MiB 限制只涵盖
响应正文，没有额外施加响应头总字节数上限。

## 验收与下一步

本轮 Native 验收为 38/38 测试通过。测试覆盖 fake transport、配置优先级/文件错误、凭据 origin 隔离、
HTTP 错误分类、取消、trace 失败保留远端结果、JSONL 脱敏，以及真实 loopback
HTTP 到 trace 文件的完整路径。验证命令：

```sh
moon check --deny-warn
moon check --target all --deny-warn
moon test --target native --strip -j 1
moon info
moon fmt
```

`--target all` 类型检查不等于所有平台运行时都完成验收；Native 测试在当前
macOS 环境执行。没有访问真实 token 或修改 MoonHub 服务端。

后续的 [Increment 2](increment-2.md) 已接入 `/meta`、当前用户、repo/issue/MR
只读命令、业务 JSON 输出和分页。联调前需确认服务器协议；token 签发、权限范围及失效规则仍由服务端
定义。当前 SDK 不依赖这些未定规则即可进行本地开发和测试。
