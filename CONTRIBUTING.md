# 参与贡献

感谢你愿意改进 cvMaster。项目同时维护 macOS（SwiftUI / AppKit）和 Windows（.NET / WPF）两套原生实现；它们共享产品行为，但不强行共享 UI 代码。

## 开始之前

- **安全问题不要开公开 Issue。** 请按 [SECURITY.md](SECURITY.md) 私下报告。
- 小修复可以直接提 Pull Request；涉及数据模型、采集策略、粘贴目标、权限、依赖或跨平台行为变化的改动，建议先开 Issue 说明动机和边界。
- 不要在 Issue、PR、截图或测试数据中放入真实剪贴板内容、历史数据库、日志、文件名、账号、证书或本机路径。请使用合成数据并脱敏。

## 开发环境

### macOS

- Apple Silicon、macOS 26.5+、Swift 6.4 / Xcode 26.5+。
- 构建：`./native/scripts/build-app.sh`
- 隔离回归：`./native/scripts/check-regressions.sh`
- 回归会使用自建临时目录，不启动应用，不读取真实剪贴板或用户历史。

### Windows

- Windows 10/11、.NET SDK 10.0.402+（版本由 `windows/global.json` 固定）。
- 仅构建和测试：`cd windows; powershell -ExecutionPolicy Bypass -File .\build.ps1 -SkipPublish`
- 分组存储的跨平台隔离检查：按 [`windows/README.md`](windows/README.md) 使用 `--groups-only`。
- 修改 Win32 / WPF / 剪贴板 / 粘贴代码后，必须在真实 Windows 环境完成构建和交互验证；Linux 或 macOS 上的交叉编译不能替代。

## 修改原则

1. **先保证隐私边界。** 默认不记录、暂停 / 锁屏 / 安全输入不采集、排除应用和敏感标记必须继续生效。新增采集路径要说明失败、超时和状态变化时的行为。
2. **不要让内容进入日志。** 日志只允许固定错误码、阶段和必要的非内容状态；不要记录正文、完整路径、窗口标题或输入框内容。
3. **保持双平台行为可解释。** 同一功能尽量在两端保持一致；确有平台差异时，在 PR 和 `docs/` 中写明原因与用户可见影响。
4. **限制资源。** 新增剪贴板格式、图片解码、搜索或文件访问时，必须设置大小、数量、并发或超时上限。
5. **不引入隐式网络行为。** 不添加遥测、崩溃上传、远程字体 / 图标 / 脚本或后台 HTTP 请求。需要网络能力的功能应先讨论。
6. **依赖要克制。** 新增第三方库前先开 Issue，说明许可证、维护状态、体积和是否可用系统能力替代。

## 代码风格

- Swift：遵循现有 Swift 6 严格并发写法；生产代码应通过 `-strict-concurrency=complete -warnings-as-errors` 类型检查。不要在主线程执行阻塞 I/O 或大内容解码。
- C#：保持 nullable、参数绑定 SQL、`using` / `await using` 释放资源；UI 线程不做阻塞文件或剪贴板操作。
- 注释解释“为什么”和边界，不重复代码表面行为。中文注释与现有代码保持一致。
- 不要顺手重排无关代码；一个 PR 尽量只解决一个问题。

## 测试与验证

提交前至少执行与改动平台对应的命令，并在 PR 中贴出实际结果：

```bash
# macOS
./native/scripts/check-regressions.sh

# macOS 自动粘贴 / AX 变更：额外启动独立 AppKit 目标进程，需辅助功能权限
./native/scripts/check-regressions.sh --ax

# Windows
cd windows
powershell -ExecutionPolicy Bypass -File .\build.ps1 -SkipPublish

# Windows 格式检查（需先 restore；仓库已启用 EnforceCodeStyleInBuild）
dotnet format cvMaster.slnx --verify-no-changes
```

如果只做了静态检查、只验证了一个平台，或某项交互无法自动化，请在 PR 中明确写出“未执行 / 未验证”，不要用旧结果代替当前代码的结果。

## 提交与 PR

- 提交信息沿用仓库现有风格，例如 `fix(剪贴板): ...`、`docs(隐私): ...`、`build(windows): ...`。
- PR 描述请包含：改动目的、用户可见变化、隐私 / 安全影响、测试命令与结果、未验证项。
- 涉及界面变化时附截图；截图必须使用合成数据，并检查是否包含个人信息。
- 不要提交构建产物、数据库、日志、证书、密钥或编辑器配置。
- 提交即表示你同意以本项目的 [Apache License 2.0](LICENSE) 授权你的贡献；项目当前不要求签署 CLA。

## 文档

行为、默认值、数据范围、权限或网络行为发生变化时，同步更新：

- [`README.md`](README.md)
- [`docs/隐私与数据说明.md`](docs/隐私与数据说明.md)
- 对应平台的 README 或设计文档
- 如涉及验证状态，更新验证记录，并区分“已执行”和“未执行”。
