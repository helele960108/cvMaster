# cvMaster for Windows

Windows 版是原生 .NET 10 / WPF 托盘应用，参考 macOS 版的浮层、分组、筛选、预览与保留策略实现。没有 WebView、没有 Electron、没有后台网络请求。

## 环境

- Windows 10 / Windows 11，x64 或 arm64。
- 源码构建需要 .NET SDK 10.0.402+（由 `global.json` 固定）。
- 发布自包含版本后，目标机器无需预装 .NET。

## 构建、测试与发布

在 `windows/` 目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

产物位于 `dist/win-x64/`。脚本按以下顺序执行：

1. `dotnet build cvMaster.slnx -c Release`
2. 运行 `CvMaster.SmokeTests` 的 37 项核心检查
3. `dotnet publish` 自包含版本

常用参数：

```powershell
# 仅构建和测试，不发布
.\build.ps1 -SkipPublish

# 框架依赖发布（体积小，但目标机器需安装 .NET 10 Desktop Runtime）
.\build.ps1 -FrameworkDependent

# 单文件自包含发布（首次启动会解压原生库，体积更小）
.\build.ps1 -SingleFile

# Windows on Arm
.\build.ps1 -Runtime win-arm64
```

如果 `dotnet` 未加入 `PATH`，脚本会依次查找：

- `%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe`
- `%ProgramFiles%\dotnet\dotnet.exe`
- `%ProgramFiles(x86)%\dotnet\dotnet.exe`
- `%USERPROFILE%\.dotnet\dotnet.exe`

## 本地部署

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
```

默认行为：

- 重新构建、运行 37 项测试并发布自包含版本；
- 安装到 `%LOCALAPPDATA%\Programs\cvMaster`；
- 创建开始菜单快捷方式 `cvMaster`；
- 启动应用；
- 不写入开机启动项，不请求管理员权限，不修改 `%LOCALAPPDATA%\cvMaster` 中的用户数据。

常用参数：

```powershell
# 直接部署 dist 中已有产物
.\deploy.ps1 -SkipBuild

# 部署但不启动
.\deploy.ps1 -NoLaunch

# 不创建快捷方式
.\deploy.ps1 -NoShortcut
```

卸载：退出 cvMaster，删除 `%LOCALAPPDATA%\Programs\cvMaster` 和开始菜单快捷方式。是否删除 `%LOCALAPPDATA%\cvMaster` 由用户决定；删除后历史、分组和日志都会消失，但不会删除记录中引用的原文件。

## 开发运行

```powershell
dotnet build cvMaster.slnx
dotnet run --project src/CvMaster/CvMaster.csproj
```

直接运行 `src/CvMaster/bin/Debug/net10.0-windows/cvMaster.exe` 时，如果 apphost 找不到用户目录下的运行时，可设置：

```powershell
$env:DOTNET_ROOT = "$env:LOCALAPPDATA\Microsoft\dotnet"
```

`dotnet run` 不需要该设置。

## 使用

| 操作 | 方式 |
| --- | --- |
| 打开/收起浮层 | 点击托盘图标或 `Alt+Space` |
| 搜索 | 打开后直接输入；`Ctrl+F` 聚焦搜索 |
| 上下选择 | `↑` / `↓` |
| 粘贴 | `Enter` 或双击记录 |
| 纯文本粘贴 | 右键菜单 |
| 侧边预览 | 悬停记录 280 ms，或点击记录右下角类型按钮 |
| 置顶 / 分组 / 删除 | 右键菜单；预览中可置顶 |
| 新建 / 重命名分组 | 顶部 `…` 菜单 |
| 暂停 / 恢复记录 | 更多菜单；暂停时也可点击右上角“已暂停”状态胶囊 |
| 调整浮层高度 | 拖动远离托盘图标一侧的把手（420–1000 DIP） |
| 打开设置 | `Ctrl+,` 或 `…` / 托盘菜单 |
| 收起 | `Esc` 或点击其他窗口 |

首次启动默认不记录剪贴板。需要先在浮层顶部横幅或设置中开启。停靠托盘运行，不显示常驻主窗口。

## 数据位置

- 数据库与内容资产：`%LocalAppData%\cvMaster\`
  - `history.sqlite`
  - `assets/`
  - `logs/cvmaster.log`（只记录级别与错误码，滚动上限约 256 KB）
- 设置：`HKCU\Software\cvMaster`
- 部署脚本不会写入开机启动项，也不注册服务或计划任务。

删除 `%LocalAppData%\cvMaster` 会移除全部历史与分组；不会删除记录中引用的用户原文件。

## 项目结构

```text
windows/
├─ src/CvMaster.Core/
│  ├─ Models.cs               轻量记录、分组、表示与查询模型
│  ├─ HistoryStore.cs         SQLite 串行存储、事务、去重、检索与清理
│  ├─ TextExtraction.cs       HTML / RTF 安全文本提取
│  └─ Fingerprint.cs          SHA-256 内容指纹
├─ src/CvMaster/
│  ├─ App.xaml(.cs)           单实例、托盘常驻、生命周期
│  ├─ Services/               剪贴板、粘贴、热键、主题、设置、缩略图
│  ├─ ViewModels/             浮层投影、搜索防抖、状态编排
│  ├─ Views/                  浮层、侧边预览、设置、文本输入
│  ├─ Controls/               图标、微卡片、来源徽标
│  ├─ Themes/                 暖中性浅色/深色主题与控件样式
│  └─ Interop/                Win32 / DWM / Shell / SendInput
├─ src/CvMaster.SmokeTests/   无 UI 的核心回归检查
├─ tools/generate-icon.py     生成应用图标
├─ build.ps1                  构建、测试与发布
└─ deploy.ps1                 本地部署与开始菜单快捷方式
```

## 实现要点

- **事件驱动**：使用 `AddClipboardFormatListener` 监听 `WM_CLIPBOARDUPDATE`，不做 500 ms 定时轮询。
- **合并写入**：Windows 剪贴板常见“先清空再写入”会产生连续通知；监听器延迟 60 ms 读取稳定序列，最多重试 3 次，避免丢弃最终内容。
- **有界采集**：单表示 8 MB、单条 16 MB、最多 24 个表示、100 个文件引用；图片在解码前检查像素上限。
- **STA 工作线程**：剪贴板读取和磁盘操作不阻塞 UI；缩略图按需解码，LRU 缓存 24 张 / 2 MB。
- **序列防自身触发**：应用写回剪贴板后按序列号抑制自身通知，不重复入库。
- **定向粘贴**：打开浮层前记录原前台窗口；粘贴前校验窗口、进程与完整性级别，恢复焦点后发送标准 `Ctrl+V`。
- **日志最小化**：只写时间、级别与错误码，不写正文、文件名或完整路径。

## 验证

当前已通过：

- `dotnet build cvMaster.slnx -c Release`：0 警告、0 错误。
- 核心冒烟测试：`ALL PASS (37 checks)`。
- 自包含发布产物可在未设置 `DOTNET_ROOT` 的情况下启动。
- 手动验证：托盘热键打开浮层、文本 / 链接 / 图片 / 文件引用采集、去重、侧边预览、分组创建、设置页、浅色与深色主题、125% DPI 截图、定向粘贴到独立外部文本框。
- 空历史启动 4 秒后实测：工作集约 103 MB，私有内存约 54 MB（Windows 11 x64，125% DPI，发布版）；会随字体缓存、图片解码和系统组件变化。
- 已部署到 `%LOCALAPPDATA%\Programs\cvMaster` 并完成文本/链接/图片/文件采集、搜索、悬停预览、定向粘贴、设置页、重启持久化与单实例验证；详见 [`docs/Windows验证记录.md`](../docs/Windows验证记录.md)。

仍需在更多真实环境补充：多显示器与混合 DPI、全屏应用、触摸键盘、辅助技术、睡眠唤醒、10,000 条 / 1 GB 极限数据、磁盘满与损坏库恢复、粘贴到不同完整性级别目标。
