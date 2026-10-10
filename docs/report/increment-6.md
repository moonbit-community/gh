# Increment 6：可验证的本地 Native 交付候选

> 历史报告：保留当时的实现范围、限制和验收数字，不代表当前使用说明。
> 当前行为、命令和平台边界见[文档索引](../README.md)。

状态：**路线 B 已实现；每次候选的验收结果由完成清单和本轮日志记录**。

本轮只修改 gh 客户端仓库，落实 [架构书](../architecture.md) 的发布准备工作。
选路原因和未选择的服务端路线见 [范围选择记录](increment-6-proposal.md)。
MoonHub `/api/v1`、用户 API token 生命周期及真实服务器联调继续是独立门槛。

## 冻结范围

1. 新增 `scripts/release_candidate.mbtx`。复用固定版本的 async 文件／进程库、
   core JSON 和上游 SHA-256，串行执行检查、Native 测试、release 构建，创建
   全新的候选目录。项目自动化保持 `.mbtx`，不增加项目 FFI 或手写散列算法。
2. 四个已有 smoke 脚本统一支持 `[BINARY [REPORT]]`。报告绑定实际测试文件
   的路径、大小和 SHA-256，允许候选目录接收本轮独立报告。
3. 将待交付二进制先复制到候选目录，再对这一份执行 `--version`、`--help`
   和全部四套 CLI smoke；复制前的测试或历史报告不能替代这一步。
4. 候选目录携带 LICENSE、使用说明、契约文档和 fresh evidence。所有必须
   检查通过且文件摘要核对成功后，才写 `manifest.json` 完成标记。
5. 记录实际 OS/architecture、完整 MoonBit toolchain、固定依赖、每条检查的
   exit 状态、交付文件大小／SHA-256，以及可空 Git revision、dirty/untracked
   状态。清单显式保留 `published: false`、`live_server_verified: false`。
6. 给出 macOS/Linux/Windows 原生执行步骤；平台结果分别验收，不能把
   `moon check --target all` 当成三个系统的运行证据。
7. 提供并随候选携带 `scripts/verify_candidate.mbtx`，离线核对全部清单文件
   的大小／SHA-256、目录 inventory、十一项必需检查及四份 smoke 的二进制摘要和
   场景数。通过临时副本破坏测试独立验证候选工具的失败边界。

不在本轮范围：MoonHub 服务端修改、真实账户操作、API/token 协议扩展、压缩包
格式实现、签名、托管上传、Mooncakes 发布、自动更新、仓库 URL 选择及首次
Git 提交。候选可由尚未提交的开发源码生成，但清单必须如实记录，不能声称它
是由一个不存在的提交复现得到。

## 执行方式与产物

在源代码仓库根目录执行，Moon 命令串行运行：

```sh
moon update
moon run --target native scripts/release_candidate.mbtx
```

默认在 `_build/releases` 下创建新目录。也可指定一个**尚未存在**的路径；
自定义路径的父目录须已存在。macOS/Linux 示例：

```sh
mkdir -p _build/releases
moon run --target native scripts/release_candidate.mbtx -- _build/releases/local-candidate-1
```

预期候选结构：

```text
<candidate>/
  bin/moonhub-gh             # Windows: moonhub-gh.exe
  LICENSE
  README.md
  moon.mod.txt                 # metadata snapshot, not a nested build project
  licenses/
  docs/
  scripts/verify_candidate.mbtx
  evidence/
    read-smoke.json
    mutation-smoke.json
    operations-smoke.json
    api-smoke.json
    <step>.stdout.log
    <step>.stderr.log
  runner-status.json        # running / failed / complete and current step
  manifest.json             # only after successful completion
```

清单以实际文件枚举和摘要为准；它自身不做递归自摘要。它是本地一致性与执行
记录，不是发行签名，也不是抵抗恶意修改的证明。失败后保留的候选可能有部分
文件，但没有完成清单；修复原因后使用新的目录重新运行，不合并旧证据。

模块元数据以 `moon.mod.txt` 保存，避免 IDE 把交付目录识别为待构建的嵌套项目。
runner 在写入完成清单前也检查额外文件；构建缓存等未登记文件不能被悄悄打包。
`runner-status.json` 记录已启动步骤及其退出状态；进程未成功启动或超时可能没有
退出码，不能将 null 当作 0。失败时优先查看它和对应 stdout/stderr 日志。

从源码仓库验证指定候选：

```sh
moon run --target native scripts/verify_candidate.mbtx -- _build/releases/local-candidate-1
```

候选复制或移动后，可在新位置使用它自带的 verifier；从候选根目录执行：

```sh
moon run --target native --target-dir ../gh-verifier-build scripts/verify_candidate.mbtx -- .
```

`--target-dir` 必须指向候选目录以外的构建缓存位置，否则 Moon 会在脚本旁生成
`scripts/_build`，文件清单会正确拒绝这些额外文件。若省略参数造成了这种情况，
重新使用完整候选副本，并按上述方式在包外构建。
验证器依据相对文件清单和二进制摘要，不要求报告里记录的原始绝对路径仍存在。
它拒绝缺少清单、遗漏／额外文件、内容变化、未完成检查或不匹配的 smoke 证据。
它**不会运行候选二进制或访问 MoonHub**；“离线”指证据检查本身不发网络请求，
执行 MoonBit 脚本所需的固定依赖应预先缓存。摘要一致不能代替发行者签名或可信
来源验证，攻击者若能同时替换清单和文件，普通散列并不提供身份保证。

候选工具自身的回归单独运行，在临时副本上验证破坏、缺清单、已有目录保护、
旧 report 等边界，不改变输入候选：

```sh
moon run --target native scripts/release_smoke.mbtx -- _build/releases/local-candidate-1
```

本轮预期报告位置为 `_build/increment-6-smoke.json`；它属于工具回归，不能替代
候选内的四套共 66 组功能 smoke。本轮实际结果见下面的执行记录。

现有固定依赖没有已验证的 tar/zip writer，因此首份产物选择目录。压缩分发若
成为要求，应先评估可复用社区库，不在本轮增加通用归档实现。

## 验收条件

| 检查 | 本轮必须达到的结果 |
| --- | --- |
| Native 和全目标 `moon check --deny-warn` | 无警告通过；全目标只作为类型检查 |
| `moon test --target native --strip -j 1` | 全部通过，保留本轮实际输出 |
| Native release build | 成功产生待交付二进制 |
| staged binary 的 version/help | 返回 0，输出符合现有 CLI 身份与命令面 |
| read smoke | 14 组，通过且报告绑定 staged binary |
| mutation smoke | 14 组，通过且报告绑定同一 staged binary |
| operations smoke | 20 组，通过且报告绑定同一 staged binary |
| generic API smoke | 18 组，通过且报告绑定同一 staged binary |
| 清单和文件一致性 | 交付文件大小／SHA-256 一致，记录真实平台、版本和源码状态 |
| 离线 verifier | 脚本无警告编译；完整／移动候选可验证，不运行二进制；十一项检查和四份报告一致 |
| 工具失败边界 | 独立 release smoke 通过；已有 OUTPUT 被拒绝，坏候选／旧报告不能伪装完成 |
| 格式与公开接口 | 最后运行 `moon info`、`moon fmt` 并审阅生成接口 |

四套 smoke 合计 **66 组**，这是预定验收量，不是尚未执行步骤的通过声明。
它们启动真实 Native CLI，使用 loopback HTTP fixtures 和临时文件，验证可执行
文件层面的客户端行为；它们没有运行真实 MoonHub，也没有测试公网 TLS。

## 本轮执行记录

执行记录以本次生成的文件为准，不把人工填写的通过状态带入下一次候选：

- 候选路径由 runner 最后输出；`manifest.json` 记录实际平台、完整 toolchain、
  文件摘要、源码状态及十一项检查的退出码（含随包 verifier 的编译检查）。
- Native 测试数量见 `evidence/test.stdout.log`；构建和类型检查分别保留日志。
- 四份 `evidence/*-smoke.json` 记录 66 组场景及实际二进制身份。
- `_build/increment-6-smoke.json` 记录工具边界回归，并绑定被测候选清单摘要。
- `moon info`、`moon fmt` 是仓库交接检查，不改写已经完成的候选。

完成后以候选内 `manifest.json` 与 `evidence/*.json` 为机器可核对的证据位置；
报告中的 binary path/size/SHA-256 必须与该候选的 staged binary 一致。
`_build` 是本地生成产物，默认不纳入 Git；后续移交时需携带完整候选目录。

## 仍需独立完成的发布门槛

2026-10-10 的 hosted Native CI 已在 Linux x64、macOS arm64、Windows x64
分别通过 134 项测试、66 个 CLI fixture 场景和 16 项发布工具回归。源码提交、
运行链接和下载产物核验记录见 [CI 历史报告](native-ci-2026-10-10.md#execution-record)。这些结果仅覆盖
实际执行的 runner 和场景，不代替下列独立发布门槛。
宿主信息来自 Unix `uname` 或 Windows 处理器环境变量，不是对可执行文件头的
架构鉴定；跨架构工具链或兼容层运行需要另行核对实际二进制格式。
跨平台命令和停止条件见[发布说明](../development/release.md#native-platform-handoff)。

在声明一个平台可发布前，还要单独记录系统 TLS 信任链与无效证书拒绝、并发
trace 锁、凭据／trace 文件权限或 Windows ACL、stdin/EOF、Unicode 路径与
取消行为。当前 socket fixture 并不覆盖这些全部场景，特别不证明真实服务器
在客户端取消后的写入状态。

服务端的 Bearer 发放／撤销／过期、权限过滤、真实分页、原子 ETag、异步 MR
合并、pipeline 取消和快照重跑仍需实际 MoonHub 实现及联调。候选目录生成
成功只完成本增量交付准备，不关闭这些门槛，也不表示已经正式发布。
