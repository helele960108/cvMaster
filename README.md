# cvMaster

本地优先的剪贴板管理工具。原项目以 macOS 菜单栏形态设计，本仓库同时包含 macOS 原生实现与 Windows 原生实现，共享同一套产品约束：只在本机工作、首次使用默认不记录、内容不进入日志、按需读取大内容。

## 两个原生实现

| 平台 | 技术栈 | 入口 | 数据目录 |
| --- | --- | --- | --- |
| macOS | SwiftUI + AppKit | 菜单栏图标 + `⌥Space` | `~/Library/Application Support/cvMaster` |
| Windows | .NET 10 + WPF | 托盘图标 + `Alt+Space` | `%LocalAppData%\cvMaster` |

Windows 版不是 WebView 包装，也不依赖 Electron；界面使用原生 WPF 控件、Win32 托盘与全局热键，剪贴板通过 `WM_CLIPBOARDUPDATE` 事件驱动读取。

## 仓库结构

```text
cvMaster/
├─ native/                    macOS SwiftUI / AppKit 实现
├─ windows/
│  ├─ src/CvMaster.Core/      数据模型、SQLite 存储、文本提取与容量策略
│  ├─ src/CvMaster/           WPF 壳层、托盘、热键、剪贴板、粘贴与界面
│  ├─ src/CvMaster.SmokeTests/核心冒烟测试（37 项）
│  ├─ tools/                  图标生成脚本
│  ├─ build.ps1               构建、测试与发布脚本
│  ├─ deploy.ps1              本地部署与开始菜单快捷方式
│  ├─ cvMaster.slnx           解决方案
│  └─ README.md               Windows 构建与使用说明
├─ design/                    交互与视觉探索稿
├─ docs/
│  ├─ 概要设计.md             macOS 产品与数据设计
│  ├─ UI设计.md               macOS 交互与视觉规范
│  ├─ 性能与实现约束.md       macOS 性能预算
│  ├─ Windows版设计.md        Windows 架构、差异、安全与验收
│  └─ Windows验证记录.md      Windows 本地部署与基础功能验证结果
└─ README.md
```

## Windows 快速开始

需要 Windows 10/11 x64 与 .NET SDK 10（仅源码构建需要；自包含发布产物不要求目标机器安装 .NET）。

```powershell
cd windows
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

脚本会执行 Release 构建、37 项核心冒烟测试，并发布自包含版本到 `windows/dist/win-x64/`。直接运行 `windows/dist/win-x64/cvMaster.exe`。

本地部署（安装到当前用户目录、创建开始菜单快捷方式并启动，不需要管理员权限）：

```powershell
cd windows
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
```

开发运行：

```powershell
dotnet run --project windows/src/CvMaster/CvMaster.csproj
```

如果本机 `dotnet` 安装在用户目录但未加入 `PATH`，可先设置 `DOTNET_ROOT`，或直接使用脚本中自动探测到的 SDK。详见 [`windows/README.md`](windows/README.md)。

## 核心行为

- 只保留托盘图标，不创建常驻主窗口；点击托盘或按 `Alt+Space` 打开浮层。
- 首次启动默认关闭记录，需要用户在浮层或设置中明确开启。
- 文本、链接、图片、文件引用按受控格式保存；同一内容去重并累计复制次数。
- 上下键选择，`Enter` 或双击粘贴；`Esc` 收起；右键菜单提供纯文本粘贴、置顶、分组和删除。
- 悬停 280 ms 显示侧边预览，不占用主列表高度。
- 分组、置顶、类型筛选、时间筛选、搜索和保留策略与 macOS 版保持同一信息架构。
- 所有内容仅保存在本机；不联网、不使用 WebView、不把内容或路径写入日志。

## 安全与限制

- 识别 `ExcludeClipboardContentFromMonitorProcessing`、`Clipboard Viewer Ignore`、`CanIncludeInClipboardHistory=0` 与 `org.nspasteboard.*` 等隐私标记。
- 默认排除 1Password、Bitwarden、KeePass、KeePassXC，并支持按进程名继续添加。
- 自动粘贴在恢复原窗口后通过 `SendInput` 发送 `Ctrl+V`；目标完整性级别高于当前进程时拒绝发送。
- 敏感标记和来源排除不是绝对安全边界，不能保证识别所有密码。
- 数据未做应用级加密；文件记录只保存引用，不备份或删除原文件。

## 文档

- macOS 产品与数据设计：[docs/概要设计.md](docs/概要设计.md)
- macOS 交互与视觉规范：[docs/UI设计.md](docs/UI设计.md)
- macOS 性能预算：[docs/性能与实现约束.md](docs/性能与实现约束.md)
- Windows 架构与实现差异：[docs/Windows版设计.md](docs/Windows版设计.md)
- Windows 本地部署与验证结果：[docs/Windows验证记录.md](docs/Windows验证记录.md)
- Windows 构建说明：[windows/README.md](windows/README.md)
