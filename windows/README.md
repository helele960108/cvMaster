# cvMaster for Windows

Windows 版是原生 .NET 10 / WPF 托盘应用，参考 macOS 版的浮层、分组、筛选、预览与保留策略实现。没有 WebView、没有 Electron、没有后台网络请求。

> 当前处于预览阶段，Windows 端不提供安装包（macOS 预览包见仓库 Releases）。`packaging/` 中的 Inno Setup 配置仅保留给后续发布流程使用。

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
2. 运行 `CvMaster.SmokeTests` 的核心冒烟测试（含分组隔离用例；具体数量以 `ALL PASS (N checks)` 输出为准）
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

## 应用图标

使用与 macOS 一致的透明底、单色圆润 CV 标志。主图为 `native/Resources/AppIcon.png`，矢量源为相邻的 `AppIcon.svg`；不再生成旧铜橙剪贴板。安装 Python / Pillow 后，在仓库根目录执行：

```bash
python3 windows/tools/generate-icon.py
python3 windows/tools/check-icons.py
```

生成 `Assets/app.png`（1024 px）及九尺寸 `Assets/app.ico`（16–256 px）。ICO 编译嵌入 EXE，托盘和快捷方式取 EXE 内嵌图标，因此更换后须重新构建并退出旧进程再启动；仅复制 Assets 不会更新运行中的托盘。Windows 使用固定深色标志，浅 / 深色任务栏下的实际对比度仍需 Windows 人工验收，不宣称像 macOS 模板图一样自动反色。

## 本地部署

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy.ps1
```

默认行为：

- 重新构建、运行核心冒烟与分组隔离测试并发布自包含版本；
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

仅验证分组存储与事务（使用独立临时目录，不启动 UI）：

```powershell
dotnet run --project src/CvMaster.SmokeTests/CvMaster.SmokeTests.csproj -- --groups-only
```

`--groups-only` 不调用依赖 Win32 的原始表示恢复，适合在具备匹配 .NET SDK 的非 Windows 主机做分组隔离验证；默认完整冒烟仍需 Windows。项目 SDK 版本以 `global.json` 为准。交叉构建 WPF 只证明编译，不代表 Windows 界面验收。

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
| 新建分组 | 顶部 `…` 菜单或分组栏加号 |
| 重命名 / 排序 / 删除分组 | 用户分组右键，或 `… → 当前分组`；使用“前移 / 后移”调整顺序 |
| 暂停 / 恢复记录 | 更多菜单；暂停时也可点击右上角“已暂停”状态胶囊 |
| 调整浮层高度 | 拖动远离托盘图标一侧的把手（420–1000 DIP） |
| 打开设置 | `Ctrl+,` 或 `…` / 托盘菜单 |
| 收起 | `Esc` 或点击其他窗口 |

首次启动默认不记录剪贴板。需要先在浮层顶部横幅或设置中开启。停靠托盘运行，不显示常驻主窗口。

分组排序只调整用户分组，“全部 / 置顶”固定在前，首组不能前移、末组不能后移；顺序持久保存，条目“加入分组”菜单使用相同顺序。排序不重查历史、不重置搜索条件、记录选择或已加载数量，本次不提供拖拽。

删除分组前使用原生二次确认（默认取消，Esc 可取消），只删除分组及其归属关系，不删除历史、内容资产或引用的原文件。若完成时仍选中被删分组，回到“全部”并保留关键词、类型和时间筛选；否则保留当前分组。删除最后一个所属分组后，记录未来仍遵循既有保留策略，但删除分组本身不触发历史清理。分组写入和目录回读期间禁用重复变更，名称最多 20 个文本元素且不超过 1024 UTF-8 字节。

## 数据位置

- 数据库与内容资产：`%LocalAppData%\cvMaster\`
  - `history.sqlite`
  - `assets/`
  - `logs/cvmaster.log`（只记录级别与错误码，滚动上限约 256 KB）
- 设置：`HKCU\Software\cvMaster`
- 部署脚本不会写入开机启动项，也不注册服务或计划任务。

删除 `%LocalAppData%\cvMaster` 会移除全部历史与分组；不会删除记录中引用的用户原文件。

## 隐私

- 首次启动默认关闭记录；开启后只采集新的剪贴板变化，不回溯开启前内容。
- 默认排除 1Password、Bitwarden、KeePass、KeePassXC，并识别系统隐私标记。
- 日志只记录固定错误码和时间，不记录正文、完整路径或进程名。
- 数据未做应用级加密；删除历史不等于清空系统剪贴板或安全擦除备份。

完整的数据范围、保存位置、保留策略和已知限制见 [`docs/隐私与数据说明.md`](../docs/隐私与数据说明.md)。

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
- **定向粘贴**：打开浮层前记录原前台窗口；读取内容前校验目标存活且前台为原目标或本应用。收起浮层后等待目标实际前台、修饰键释放并连续稳定 100 ms（最长 2.5 秒），再写剪贴板并发送标准 `Ctrl+V`；写入后发送失败只提示手动粘贴。
- **失败重开**：仅在原目标仍存活且前台仍是目标或本应用时重开列表，第三方应用在前台时改用托盘气泡。
- **日志最小化**：只写时间、级别与错误码，不写正文、文件名或完整路径。

## 验证

以下是历史验证结果，**不代表当前提交**；当前快照仍需在 Windows 上重新构建、运行测试并完成交互验收：

- `dotnet build cvMaster.slnx -c Release`：0 警告、0 错误。
- 历史核心冒烟测试：`ALL PASS (39 checks)`；当前测试套件已加入分组隔离用例，数量以实际输出为准。
- 自包含发布产物可在未设置 `DOTNET_ROOT` 的情况下启动。
- 手动验证：托盘热键打开浮层、文本 / 链接 / 图片 / 文件引用采集、去重、侧边预览、分组创建、设置页、浅色与深色主题、125% DPI 截图、定向粘贴到独立外部文本框。
- 空历史启动 4 秒后实测：工作集约 103 MB，私有内存约 54 MB（Windows 11 x64，125% DPI，发布版）；会随字体缓存、图片解码和系统组件变化。
- 已部署到 `%LOCALAPPDATA%\Programs\cvMaster` 并完成文本/链接/图片/文件采集、搜索、悬停预览、定向粘贴、设置页、重启持久化与单实例验证；详见 [`docs/Windows验证记录.md`](../docs/Windows验证记录.md)。

仍需在更多真实环境补充：多显示器与混合 DPI、全屏应用、触摸键盘、辅助技术、睡眠唤醒、10,000 条 / 1 GB 极限数据、磁盘满与损坏库恢复、粘贴到不同完整性级别目标。
