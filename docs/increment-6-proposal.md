# Increment 6：范围选择记录

状态：**已选择路线 B：只在 gh 仓库完成本地 Native 交付候选与平台准备**。

提出本文件时，[架构书](architecture.md) 的增量清单到 Increment 5 为止。
用户随后明确选择路线 B，现已写入架构书，准确范围和验收见
[Increment 6](increment-6.md)。路线 A 保留为未来选项，本轮不修改 MoonHub
服务端，不将服务器实现或真实联调计为完成。

核查基线：MoonHub `672b8b56be2feeb9f2c214da69a603334499bad1`，工作区干净；
gh 当时无 Git HEAD/remote，源码尚未纳入首次提交。交付清单必须重新读取实际
Git 状态，不能将这里的历史核查结果当作构建身份。

## 路线 A：MoonHub 最小公开 API 与真实 CLI 联调（未选择、未实施）

这是架构书第 13 节所写“最小下一步证据”的落实，涉及 **moonhub 和 gh 两个仓库**。
本轮可验收的通路限定为：

1. 独立挂载 `/api/v1`，提供公开 `/meta`，以及 Bearer 认证后的 `/user`、
   `/repos/{owner}/{repo}`、单项 Issue 和单项 Merge Request GET。
2. 在 MoonHub `identity` 业务层增加独立用户 API token 的持久化、签发、查询、
   过期和撤销；通过本地管理命令完成初始签发和撤销，秘密仅显示一次。
3. 在现有权限检查之上增加 token 限制，第一阶段只读，权限为 token 范围与用户
   当前 ACL 的交集。浏览器 cookie 和 runner token 不能作为用户 API token。
4. 返回既有版本化 JSON、固定错误和服务端 request ID；让当前 gh 二进制真实
   调用这些端点，并验证其输出及 trace 关联。

现成能力足够复用，无需重新实现密码学或 Web 框架：

- `web/app.mbt` 已在顶层分离 assets、runner 与 browser app，适合增加 API mount。
- `identity/credentials.mbt` 已有安全随机和上游 SHA-256 token 摘要；
  `identity/accounts.mbt` 的 session 查找提供过期、撤销、active 用户检查模式。
- `repository_scope`、`require_issue`、`require_merge_request` 已提供权限范围内
  单项读取；Web 层继续通过业务包取得 DTO，不能直接写 SQL。
- `web/testkit` 已有真实 production app、SQLite、临时 Git 和随机端口 fixture。

这条路线不是简单添加几个 handler：当前没有用户 API token 表，数据库 schema
version 为 14，需正式迁移与生命周期测试。签发权限、默认有效期、仓库范围及
密码重置是否撤销 API token，要在选定路线后冻结为具体服务端政策。

已发现并需在实现中解决的映射：

- Issue 当前 DTO 返回 author/assignee 的 display_name，gh 契约需要 name_key；
  应保留浏览器显示字段，并给公开 API 提供正确身份字段。
- Issue/MR 服务端编号为 Int64，现有客户端契约限正 Int32；API 边界必须显式
  检查，不能截断转换。
- MR 的空 job_status 应输出 null，job_error 不属于公开 DTO；单项 GET 不能
  调用会写入数据库的 `refresh_merge_request`。
- 现有列表固定每页 50 且要求 status，不能直接满足客户端 page/per_page 契约。
  因而本轮最小通路只包含单项读取；列表、写入和 pipeline API 另排增量。
- 只读通路可暂不提供 ETag，当前 SDK 已接受缺省；不能用不完整的 edit_version
  冒充覆盖整个资源表示的强 ETag。

完成证据：五条 CLI 成功请求真实命中 MoonHub；无/无效/过期/撤销 token 为 401；
cookie 和 runner 凭据不能授权；私库跨用户及资源不存在遵循既有 404 策略；
坏编号 400、内部异常固定 JSON 500；请求 ID 可与 gh trace 对齐；原有浏览器与
runner 测试回归。完成本轮仍不等于全部 `/api/v1` 已实现。

## 路线 B：可验证的本地 Native 交付候选（已选择）

只修改 **gh 仓库**，对应发布门槛中的交付准备：

1. 新增 `.mbtx` 交付脚本，串行检查、测试和构建，并创建全新的候选目录。
2. 将最终二进制、LICENSE、使用说明和发布说明放入目录；直接对目录里的
   二进制运行 version/help 和四套现有 CLI smoke。
3. 让 smoke 报告明确绑定实际二进制和报告路径，防止 `_build` 中的历史成功
   报告被误当作本轮证据。
4. 生成清单，记录版本、真实 OS/architecture、toolchain、依赖、交付文件大小
   与 SHA-256、检查结果，以及可空 Git revision 和 dirty/untracked 状态。
   只在全部检查通过且文件摘要一致时写入完成标记。
5. 文档区分本地候选、跨平台验收、真实服务器验收与实际发布。

选路时，四个 smoke 脚本已接受待测二进制位置参数，但报告路径固定且缺少
二进制身份；本轮扩充为 `[BINARY [REPORT]]`。现有 `async/fs`、`async/process`
和已安装 `moonbitlang/x@0.5.5/crypto`
的 SHA-256 足以完成目录候选和证据包，无需新散列实现或额外依赖。

首轮产物可以是完整候选目录。当前依赖没有 tar/zip writer；若必须交付单文件
压缩包，应另外验证并复用合适的社区库，不为此手写通用归档格式。

完成证据：新鲜候选目录中的最终字节通过全部检查和 66 组现有 CLI 场景，清单
摘要可复核，失败不会产生成功清单。当前宿主仅验证为 macOS arm64；没有可用的
其他平台执行器证据，不能声称 Linux/Windows 已验收。

这条路线不需要编造远端 URL、首次提交或永久发行名称，也不执行发布。真实
MoonHub `/api/v1`、其他平台、签名及最终分发仍保留为后续门槛。

## 决策与完成边界

本轮执行路线 B。路线 A 的 token 政策、数据库迁移和服务端 API 仍需在未来
服务端任务中确定，不能由这次交付工作隐式决定。路线 B 的完成依据是新候选
目录和可复核执行证据，不能只凭已有测试数字或文件存在宣告通过。

候选可成功生成，与其他平台验收、真实 MoonHub 联调和正式发布是不同结论。
以 [Increment 6](increment-6.md) 的实际执行记录为准；本选择记录不替代验收报告。
