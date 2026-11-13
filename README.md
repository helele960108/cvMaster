# cvMaster

本地优先的剪贴板管理工具。macOS 版是菜单栏应用，Windows 版是原生 WPF 托盘应用；两端共享同一套产品约束：默认不记录、只在本机工作、内容不进入日志、大内容按需读取。

**项目状态：0.1.0 预览版。** [Releases](https://github.com/helele960108/cvMaster/releases) 提供 macOS（Apple Silicon）预览包，未经 Apple 公证；Windows 暂不提供安装包，需从源码构建。macOS 与 Windows 的界面、权限和跨应用粘贴仍在持续验收，不能把现有测试结果理解为面向所有环境的稳定版承诺。

## 平台与支持范围

| 平台 | 运行形态 | 技术栈 | 构建环境 | 当前状态 |
| --- | --- | --- | --- | --- |
| macOS | 菜单栏图标 + `⇧⌘V` 浮层 | SwiftUI + AppKit | Apple Silicon、macOS 26.5+、Swift 6.4 / Xcode 26.5+ | 隔离回归与构建通过；GUI / TCC / 多屏验收仍待完成 |
| Windows | 托盘图标 + `Alt+Space` 浮层 | .NET 10 + WPF | Windows 10/11、.NET SDK 10.0.402+ | 当前快照已交叉编译通过；仍需 Windows 运行与交互验收 |

两套实现都是原生应用：没有 Electron、没有 WebView 包装，也不共享 UI 层。Windows 版把领域与 SQLite 存储放在无 UI 的 `CvMaster.Core`，便于独立测试。

## 核心行为

- 首次启动默认关闭记录，必须在浮层或设置中明确开启。
- 文本、链接、图片、文件引用按受控格式保存；同一内容去重并累计复制次数。
- 上下键选择，`Enter` 或双击粘贴；`Esc` 收起；右键菜单提供纯文本粘贴、置顶、分组和删除。
- 悬停 280 ms 显示侧边预览，不占用主列表高度。
- 分组、置顶、类型筛选、时间筛选、搜索和保留策略与 macOS 版保持同一信息架构。
- 默认排除常见密码管理器，并识别系统剪贴板隐私标记。
- 自动粘贴优先恢复打开列表时的原窗口 / 输入节点；有 AX 快照时严格校验，窗口变化或切换到其他输入框会拒绝，快照不可用时退化为当前 active responder。目标身份、权限或前台状态不满足时拒绝写入或发送。

## 下载

macOS 预览包在 [Releases](https://github.com/helele960108/cvMaster/releases)，要求 Apple Silicon、macOS 26.5 及以上。下载 `cvMaster-<版本>-macos-arm64.zip`，解压后把 `cvMaster.app` 拖进「应用程序」。

预览包使用临时签名，没有 Developer ID 签名和公证，首次打开会被 Gatekeeper 拦截。可以在 Finder 中右键 `cvMaster.app` 选择「打开」，或在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/cvMaster.app
```

临时签名的辅助功能授权绑定具体构建，升级新版本后可能需要在「系统设置 › 隐私与安全性 › 辅助功能」中删除旧条目再重新授权。Release 说明里附有 SHA-256，可用 `shasum -a 256` 核对。

Windows 暂无安装包，请按下文从源码构建。

## 快速开始

### macOS

```bash
./native/scripts/build-app.sh
open ./native/.build/cvMaster.app
```

构建脚本使用当前 Xcode SDK 编译 Swift 6 源码，输出到被忽略的 `native/.build/`。优先使用可用的 Apple Development / Mac Development 证书签名；没有证书时回退临时签名并警告。开发签名不等于 Developer ID 分发签名或公证。

隔离回归（不会启动应用、不会读取真实剪贴板或历史库）：

```bash
./native/scripts/check-regressions.sh
```

涉及自动粘贴或 AX 的改动另跑真实 AX 回归；它会启动一个独立的 AppKit 目标进程，需要辅助功能权限：

```bash
./native/scripts/check-regressions.sh --ax
```

### Windows

需要 Windows 10/11 与 .NET SDK 10.0.402+。仅构建和运行冒烟测试：

```powershell
cd windows
powershell -ExecutionPolicy Bypass -File .\build.ps1 -SkipPublish
```

构建、测试并发布自包含目录：

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

产物位于 `windows/dist/win-x64/`，是可直接运行的目录，不是安装包。开发运行：

```powershell
dotnet run --project windows/src/CvMaster/CvMaster.csproj
```

更完整的构建参数、部署脚本与跨平台分组测试说明见 [`windows/README.md`](windows/README.md)。

## 隐私与安全

- **默认不记录**；开启时只采集新的剪贴板变化，不回溯开启前的内容。
- 历史、设置和原始内容保存在本机用户目录；没有账号、云同步、遥测、广告或崩溃上传。
- 应用不执行 HTML，不加载剪贴板 HTML 中的远程资源，也不使用 WebView。
- 没有应用级静态加密；macOS 数据目录权限收紧为 `0700`，文件为 `0600`，Windows 依赖当前用户配置目录的访问控制。
- 自动过期清理在写入新内容时执行；置顶和分组内容不参与自动过期。删除历史不等于清空系统剪贴板，也不等于安全擦除备份、系统快照或 SQLite 空闲页。
- 敏感标记和来源排除不是绝对安全边界。并非所有密码管理器都会设置标记，处理敏感信息前建议暂停记录。
- 文件引用可读性检查可能触发操作系统对本地磁盘、云盘或网络共享的访问；这不属于应用主动上传，但不能表述为“任何操作都绝对不联网”。

完整的数据范围、保存位置、保留策略、权限与已知限制见 **[docs/隐私与数据说明.md](docs/隐私与数据说明.md)**。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告，不要在公开 Issue 中粘贴真实剪贴板内容、数据库或未脱敏日志。

## 仓库结构

```text
cvMaster/
├─ native/                    macOS SwiftUI / AppKit 实现
│  ├─ CVMaster/               采集、存储、粘贴、浮层与设置
│  ├─ Validation/             隔离回归与单实例检查
│  └─ scripts/                构建与回归脚本
├─ windows/
│  ├─ src/CvMaster.Core/      模型、SQLite 存储、文本提取与容量策略
│  ├─ src/CvMaster/           WPF 壳层、托盘、热键、剪贴板、粘贴与界面
│  ├─ src/CvMaster.SmokeTests/核心冒烟与分组隔离测试
│  ├─ packaging/              Inno Setup 配置（Windows 安装包尚未发布）
│  ├─ build.ps1               构建、测试与自包含发布脚本
│  └─ README.md               Windows 构建与使用说明
├─ docs/                      产品、架构、验证与隐私文档
├─ LICENSE                    Apache License 2.0
├─ NOTICE                     版权与第三方声明入口
└─ THIRD_PARTY_NOTICES.md     第三方组件与素材许可
```

## 文档

- 隐私与数据说明：[docs/隐私与数据说明.md](docs/隐私与数据说明.md)
- macOS 产品与数据设计：[docs/概要设计.md](docs/概要设计.md)
- macOS 交互与视觉规范：[docs/UI设计.md](docs/UI设计.md)
- macOS 性能预算与实现约束：[docs/性能与实现约束.md](docs/性能与实现约束.md)
- macOS 构建、权限与行为说明：[native/README.md](native/README.md)
- Windows 架构与实现差异：[docs/Windows版设计.md](docs/Windows版设计.md)
- Windows 本地部署与验证记录：[docs/Windows验证记录.md](docs/Windows验证记录.md)
- Windows 构建说明：[windows/README.md](windows/README.md)
- 修复与隔离验证记录：[docs/修复验证记录.md](docs/修复验证记录.md)

## 参与贡献

欢迎提交 Issue 和 Pull Request。开始前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)：

- 说明复现环境、实际执行的构建 / 测试命令和未验证部分；
- 双平台行为变更尽量同时更新两套实现，或在 PR 中明确说明差异；
- 不要提交真实剪贴板内容、历史数据库、日志、证书、密钥或本机路径；
- 安全问题不要走公开 Issue，使用 [SECURITY.md](SECURITY.md) 中的私下渠道。

## 许可证

项目以 [Apache License 2.0](LICENSE) 发布，允许个人和企业自由使用、修改与分发，并包含明确的专利授权条款。第三方组件与素材的许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

Copyright 2026 helele and cvMaster contributors.
