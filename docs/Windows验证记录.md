# cvMaster Windows 基础功能验证记录

> 日期：2026-10-19
>
> 版本：0.1.0.0
>
> 环境：Windows 11 build 26300，x64，125% DPI，.NET SDK 10.0.402
>
> **说明：本文是历史验证记录，不代表当前提交。** 后续代码已继续修改，当前快照必须在 Windows 上重新构建、运行测试并完成交互验收后，才能引用为“已通过”。

## 1. 构建与部署

| 项目 | 结果 |
| --- | --- |
| Release 构建 | 0 警告、0 错误 |
| 核心冒烟测试 | 37/37 通过 |
| 发布方式 | self-contained win-x64 |
| 发布大小 | 134.5 MB |
| 安装目录 | `%LOCALAPPDATA%\Programs\cvMaster` |
| 开始菜单快捷方式 | 已创建 |
| 管理员权限 | 未使用 |
| 开机启动项 | 未写入 |

## 2. 首次启动

- 安装目录中的 `cvMaster.exe` 启动成功并保持响应。
- 用户数据目录 `%LOCALAPPDATA%\cvMaster` 自动创建，SQLite 初始化成功。
- 历史记录数为 0。
- `RecordingEnabled` 不存在，即默认关闭记录。
- 浮层可通过 `Alt+Space` 打开，物理尺寸 438×750（350×600 DIP @ 125% DPI）。
- 浮层显示“开启后自动保存新复制的内容”横幅和空状态。
- 通过界面按钮“开启记录”开启后，注册表值变为 `RecordingEnabled=1`。

## 3. 采集

保持记录开启，从外部应用复制四类内容，数据库写入结果：

| 类型 | 结果 | 保存的表示 |
| --- | --- | --- |
| 文本 | 成功 | `text/plain` |
| 链接 | 成功，识别为“链接” | `text/plain` |
| 图片 | 成功 | `image/png` |
| 文件引用 | 成功，2 个文件 | `windows/file-list` |

- 来源应用识别为 ZCode。
- 四条记录全部进入列表，分组为“今天”。
- 文件卡片显示文件数量、引用提示和表示大小；图片卡片显示缩略图。
- 侧边预览在悬停后出现，显示类型、来源、完整 URL 和大小/复制次数。

## 4. 搜索与筛选

- 在搜索框输入 `github`，结果从 4 条变为 1 条。
- 结果只保留 GitHub 链接，状态栏显示“1 条 · 本地保存”。
- 清空搜索后恢复 4 条。
- 分组、类型和时间筛选的绑定与菜单逻辑已通过核心冒烟测试及界面检查。

## 5. 定向粘贴

- 使用独立的 WinForms 文本框作为目标窗口。
- 在浮层中选中链接记录并发送 `Enter`。
- 应用恢复目标窗口后发送 `Ctrl+V`。
- 目标文本框收到的内容与记录完全一致：
  `https://github.com/helele960108/cvMaster`
- 粘贴后浮层收起，目标窗口重新获得焦点。

## 6. 设置页

- 通过 `Ctrl+,` 打开设置窗口，渲染尺寸 775×700 物理像素（620×560 DIP @ 125% DPI）。
- 通用页显示记录、自动粘贴、登录启动、快捷键和外观设置。
- 存储页显示 4 条记录、799 B 内容，保留规则为 30 天。
- 记录开关、快捷键显示和主题资源绑定正常。

## 7. 单实例与重启

- 应用运行中再次启动 `cvMaster.exe`：第二个进程自动退出。
- 进程总数保持 1，已有实例的浮层被唤起。
- 重启应用后：
  - 4 条记录全部保留；
  - 文本、链接、图片、文件类型分布不变；
  - `RecordingEnabled=1` 持久化；
  - 应用正常响应。

## 8. 清理与最终状态

- 验证产生的全部剪贴板记录、分组、记录开关与启动设置已删除；重启后仅保留避免重复首次提示的 `OnboardingShown=1`。
- 测试期间启用的登录启动与 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\cvMaster` 已删除；`deploy.ps1` 本身不创建该启动项。
- 验证前保存的原始剪贴板文本已恢复。
- 安装目录和开始菜单快捷方式保留。
- 重新启动后：
  - 应用 PID 存在且正常响应；
  - 历史记录数为 0，分组数为 0；
  - `RecordingEnabled` 不存在，首次使用仍默认关闭；
  - `RunAtStartup` 与启动项均不存在；
  - 版本号 0.1.0.0；
  - 快捷方式存在。

最终应用以干净的首次使用状态在托盘运行。

## 9. 缩放手柄位置复验

- 托盘位于屏幕底部时，浮层锚定在图标上方；手柄由底部移到浮层顶部，不再贴近任务栏与图标。
- 125% DPI 实测：浮层初始宽 438 px；从顶部手柄向上拖动后高度由 768 px 增至 906 px，底边始终保持 2091 px，即靠图标的一侧固定不动。
- 首次复验发现 Windows 屏幕坐标向下增长，顶部手柄的拖动方向被写反；修正后向上拖动正确增高。
- `PanelHeight=725` 已持久化，重启应用后按相同高度重新打开。
- Release 构建 0 警告、0 错误；37/37 冒烟检查通过。
- macOS 端按同一规则修改：浮层显示后比较状态图标与浮层的实际屏幕位置，把 18 pt 手柄放到远离图标的一侧，并反转拖动方向；当前验证环境没有 macOS / Swift 工具链，未编译运行。

## 10. 暂停状态点击恢复

- 通过“更多操作 → 暂停记录”暂停后，右上角显示“已暂停”胶囊。
- 该胶囊在 UI Automation 中的名称为“恢复记录”，控件类型为 Button。
- 使用 UIA InvokePattern 点击后，胶囊立即消失，状态栏显示“剪贴板记录已恢复”。
- 胶囊保持原有背景、圆角、间距和字号；鼠标悬停时增加 1 px 强调色描边，按下时降低不透明度。
- macOS 端将同一状态改为 Button，点击后恢复记录并显示反馈；当前环境未编译运行。

## 11. 类型筛选选中态

- 修复前：点击“文本 / 链接 / 图片 / 文件”会更新视图模型的类型条件，但胶囊选中态没有刷新，视觉上始终停在“全部类型”。
- 原因：`KindFilter` 变化没有触发 `UpdateTypeChips()`，该方法只在分组与范围变化时调用。
- 修复后：浮层监听 `KindFilter` 属性变化并刷新五个类型胶囊。
- 使用 UI Automation 与真实鼠标点击分别验证：选中背景随点击移动到目标类型；选中类型后空状态从“这里还没有内容”变为“没有匹配的内容”，点击“全部类型”后恢复。

## 12. 未覆盖项

以下未纳入本轮“基本功能验证”，仍需后续专项验收：

- 混合 DPI 多显示器、全屏应用和远程桌面。
- 中文输入法组合输入、屏幕阅读器和高对比度。
- 10,000 条 / 1 GB 数据量、长时间运行和内存峰值。
- 磁盘满、损坏数据库、权限异常和睡眠唤醒。
- 安装包签名、自动更新和卸载流程。
- 粘贴到更高完整性级别窗口（按设计会拒绝）。

## 13. macOS 端最近修复的 Windows 对齐（2026-10-20）

范围：对照 macOS 端 `852b307..d44de4a` 的修复，检查 Windows 是否存在同类问题并同步产品规则。

已修改：

- **引用文件缩略图**：存储层不再访问外部引用文件；缩略图与预览在存储队列外限时 3 秒解码，超时只停止调用方等待，卡死路径本次运行不再重试。列表同时存在内置图片与文件引用时优先使用内置像素。
- **存储事务**：去重更新、保留期 / 容量清理和新记录写入共享一个事务，提交后才回收旧资产；清空历史不再执行全库 VACUUM，资产回收与 checkpoint 作为提交后的 best-effort 维护。
- **外部文件检查**：粘贴前确认文件引用可读性移到串行存储队列之外，异常挂载点不会阻塞其他查询。
- **采集隐私**：暂停状态跨重启保存；锁屏 / UAC（输入桌面不可访问）和会话切换时跳过读取并推进基线，恢复后不补采；读取期间暂停或重置基线会丢弃在途快照。
- **表示优先级**：必要表示超限时整条拒绝；可选 HTML / RTF / 图片超限时只跳过该表示。文件引用条目只保存文件列表（可选像素），不再附带同一份路径文本。
- **粘贴交接**：先确认目标存活且前台为原目标或本应用，再收起浮层；等待目标实际前台、本应用失活、修饰键释放并连续稳定 100 ms（最长 2.5 秒）后才写剪贴板；写入后再次同步校验并派发 `Ctrl+V`。第三方应用抢先取得前台时撤销请求，不抢焦点。
- **失败重试**：只有原目标仍存活且前台仍是目标或本应用时才重开失败列表；否则使用托盘气泡说明。写入后发送失败不累计使用次数。
- **RTF**：纯文本转换共享 256 KB 解析预算，超限明确提示并保留原剪贴板。
- **快捷键**：必须包含 Ctrl / Alt / Win，拒绝仅 Ctrl 组合；录制失败保留原快捷键并继续录制。
- **界面**：空状态文案与 macOS 对齐；加载到 300 条时提示搜索缩小范围；列表行向 UI Automation 暴露合并后的整行语义。

验证结果：

- `windows/build.ps1 -SkipPublish`：Release 构建 0 警告、0 错误。
- `CvMaster.SmokeTests`：**39/39 通过**，新增“存储层不探测外部引用文件”“超预算 RTF 纯文本转换明确拒绝”。
- 本轮未启动 UI，未操作真实剪贴板、真实粘贴目标、锁屏或睡眠，因此粘贴交接、会话门禁和缩略图超时仍需真实桌面环境交互验收。

## 14. 分组删除与手动排序同步（2026-11-04）

### 实现范围

- 同步 macOS 刚完成的分组删除、前移 / 后移与相应交互保障，不扩展图片布局、批量整理或搜索引擎。Windows 默认全局快捷键仍为 `Alt+Space`。
- 用户分组右键与更多 → 当前分组共用重命名、前移、后移及删除入口；“全部 / 置顶”固定，首尾移动禁用。顺序保存到现有 `position` 字段，不修改 schema 或模型，不引入拖拽。
- 删除采用固定 GUID 和分组名称的原生确认，默认取消、Esc 可取消；只删除分组及归属，不删除历史、表示资产或原文件，不执行保留清理或资产回收。记录未来仍按既有保留策略处理。
- `SaveGroupAsync`、`DeleteGroupAsync`、`MoveGroupAsync` 共用显式 `BEGIN IMMEDIATE` 事务。移动在事务内读取最新目录、按 GUID 相邻交换并连续编号；缺失删除幂等，缺失重命名 / 移动报 `MissingGroup`，非法方向报 `Storage`。新建保留 `MAX(position)+1`，名称上限对齐 20 文本元素 / 1024 UTF-8 字节，保留 Windows 名称比较规则。
- 分组写入至目录回读共享忙碌状态，目录版本与取消令牌防止旧读覆盖；写入不随浮层关闭取消。排序不重查历史或重置筛选、选择与加载数量；删除后刷新条目归属，仅完成时仍选中被删组才回“全部”。已提交删除遇目录回读失败也不复活，读取失败不将未知目录视为空。
- 菜单与对话框使用独立计数协调自动隐藏，确认期间不因菜单关闭而隐藏父浮层。条目删除及消息弹窗复用同一对话框保护，使用 `try/finally` 收尾。

### 本轮实际验证及阻塞

- 当前主机为 macOS arm64；`dotnet`、`csc`、`msbuild`、`mono` 和 `pwsh` 不可用，常见 .NET 安装路径也没有 SDK。遵循本轮范围未擅自安装系统工具。
- 已执行 `git diff --check` 与已有暂存差异格式检查，未发现格式错误；使用 Python 标准 XML 解析器验证修改的 XAML、两个相关 csproj 及共享 `Directory.Build.props` 的 XML 语法。
- **未执行 C# 编译、WPF 交叉构建、分组隔离回归、完整冒烟、发布或部署**，也未启动 Windows GUI。XML 语法和源码复核不能代替编译或运行验证；此前 39/39 为旧代码的历史结果，不计入本轮通过项。
- 新增合成分组 suite 接入默认冒烟及 `--groups-only`，覆盖删除保历史 / 资产、顺序和新建追加、边界与非法方向、跨连接最新 GUID 定位、重新打开、命名限额、清理保组，以及 `RAISE(FAIL)` 故障注入回滚与 SQLite 完整性。测试已编写，运行结果待具备 SDK 的环境确认。
- `--groups-only` 不调用依赖 Win32 的原始表示恢复，用直接资产字节快照验证保留；未修改或弱化生产文件安全检查。测试仅使用自建临时目录，先释放存储和连接再清理；完整冒烟仍需 Windows。

### 后续执行入口

在 Windows 安装符合 `windows/global.json` 的 SDK 后，从 `windows` 目录执行：

```powershell
.\build.ps1 -SkipPublish
# 可单独重跑分组用例
dotnet run --project src/CvMaster.SmokeTests/CvMaster.SmokeTests.csproj -- --groups-only
```

实机确认分组右键与更多入口一致、首尾与忙碌禁用、删除取消 / Esc / 确认、当前和非当前分组删除、关键词 / 类型 / 时间及条目选择 / 已加载数量保持、自动隐藏保护、关闭重开与重启顺序持久化。只有上述检查实际完成后，才能更新本节为通过结论。

本轮未操作真实历史或剪贴板，未更改当前 macOS 安装版，未运行部署脚本，未 commit、未 push；保留原有工作区改动。

## 15. 开源前隐私采集修复与交叉编译验证（2026-11-04）

- **延迟读取来源绑定**：pending 请求现在同时保存来源与剪贴板序列号；读取前要求当前序列与请求一致。被排除应用、自身写入、锁屏 / 安全桌面、关闭记录或来源不可用的事件会立即作废旧 pending，避免“上一个普通应用的来源 + 最新剪贴板内容”的组合入库。
- **保存前复核**：读取前后重新检查记录状态、安全输入 / 安全桌面、排除列表和敏感过滤；状态变化时丢弃已读取快照。
- **迟到回调**：`ClipCapture` 携带采集开始时的隐私代数；暂停、关闭记录、切换敏感过滤、修改排除列表或清空历史会递增代数，UI 保存前再次校验，拒绝排队后迟到的采集。
- **验证方式**：在 macOS 上将 .NET SDK 10.0.402 临时安装到 `/tmp`（不修改系统、仓库或用户数据），执行 `dotnet build cvMaster.slnx -c Release -p:EnableWindowsTargeting=true`，结果 0 警告、0 错误；执行 `CvMaster.SmokeTests --groups-only`，`ALL PASS (95 checks)`。
- **未验证**：本机不是 Windows，无法运行 `ClipboardMonitor`、WPF UI、真实剪贴板、锁屏 / UAC、目标窗口粘贴或安装包；上述修复仍须在 Windows 实机完成采集竞态和交互验收。交叉编译只证明代码可编译，不证明运行时行为。

本轮未启动 Windows GUI、未读取真实剪贴板或历史库、未修改用户数据；新增临时 SDK 位于 `/tmp`，不属于仓库内容。

## 16. 代码质量整理（2026-11-04）

- 新增根目录 `.editorconfig`，统一基础字符集、换行、缩进和行尾空白；C# / Swift / XAML 为 4 空格，JSON / YAML 为 2 空格，PowerShell 保持 CRLF。
- `windows/Directory.Build.props` 启用 `EnforceCodeStyleInBuild=true`，让基础代码风格检查进入构建。
- 修复 `dotnet format` 报告的 C# 空格格式问题；`dotnet format cvMaster.slnx --verify-no-changes` 通过。
- 分组名称比较抽出 `CvMaster.Core.GroupNames.Equal`，UI 预检与存储层共用忽略大小写 / 宽度的同一规则，避免两套判断不一致。
- 日志时间戳改用 `CultureInfo.InvariantCulture`；快捷键解析改用泛型 `Enum.Parse<Key>`；拆分过长的 P/Invoke 常量声明。
- 验证：`dotnet build cvMaster.slnx -c Release -p:EnableWindowsTargeting=true` 0 警告、0 错误；`--groups-only` 95/95 通过。
- 保留 `PasteTargetWorker` / `PasteFocusRestorationRequest` 作为未来原输入焦点恢复的参考实现，但当前生产粘贴路径不引用；文档已明确标注。是否删除或正式接入，应在产品语义确定后单独处理，避免在本次整理中引入行为变化。

## 17. IM 文件路径扫描（2026-10-24）

目标：钉钉、企业微信、飞书复制聊天文件时，部分版本不写 `CF_HDROP`，只把路径文本写入剪贴板；为这类来源增加文件引用识别。实现为三级回退：`CF_HDROP` → `FileNameW`/`FileName` 遗留格式 → 名单内 IM 来源的保守路径文本升级（`FilePathScan`，整段文本必须全部是已存在的本地绝对路径）。范围与边界表见 `docs/Windows版设计.md` 4.4。

对第 13 节规则的一处有意例外：路径文本升级的条目在 `windows/file-list` 之外额外保留 `text/plain` 原文，粘贴到文本框仍得到路径字符串；标准 `CF_HDROP` 条目维持只保存文件列表。

自动化验证（构造与目标 IM 同名的辅助进程 `Feishu.exe` / `DingTalk.exe` / `WXWork.exe`，前台窗口属于该进程后写入剪贴板）：

| 用例 | 写入方式 | 来源进程 | 结果 | 判定 |
| --- | --- | --- | --- | --- |
| A 路径文本 | 仅纯文本（文件绝对路径） | Feishu.exe | `文件`，`windows/file-list,text/plain`，标题为文件名 | 通过 |
| B 路径文本 | 仅纯文本 | DingTalk.exe | `文件`，同上 | 通过 |
| C 路径文本 | 仅纯文本 | WXWork.exe | `文件`，同上 | 通过 |
| D 非路径文本 | 多行普通消息 | Feishu.exe | `文本`，不升级 | 通过 |
| E 路径文本非名单来源 | 仅纯文本 | chrome.exe（前台） | `文本`，不升级 | 通过 |
| F 遗留格式 | 仅 `FileNameW` | SimImCopy.exe | `文件`，仅 `windows/file-list` | 通过 |
| G 标准拖放 | `CF_HDROP` | chrome.exe（前台） | `文件`，仅 `windows/file-list`，回归无变化 | 通过 |

- 冒烟测试 **144/144 通过**（默认套件已含分组隔离回归）：新增路径扫描 9 项（单路径、多行、混合文本拒绝、相对路径拒绝、不存在拒绝、去引号、超上限、目录、空文本）与“路径升级条目保留纯文本”；Release 构建 0 警告、0 错误。
- 本机安装有飞书（未运行），未驱动真实钉钉 / 企业微信 / 飞书界面；真实 IM 的行为差异（如同时附带 HTML）若触发“剪贴板只有纯文本”之外的组合，按边界规则保持纯文本，不会误升级。
- 验证后已清理全部测试记录与临时文件，恢复 0 条历史、记录关闭状态并重启应用。

## 18. 双平台状态图标与记录提示（2026-11-26）

对应提交 `0d7166f`（`feat(icon): 统一双平台状态图标与记录提示`）。Windows 端把托盘图标从“提取 EXE 内嵌图标”改为按任务栏明暗与记录状态选择专用资源，并把状态联动从浮层窗口搬到 `App`。

### 实现要点

- 新增四份托盘资源 `Assets/tray-{dark,light}[-paused].ico`，各含 16/20/24/32/40/48/64/128/256 九个尺寸，随程序集打包（`<Resource>`），单文件发布不需要旁置文件。
- `TrayPresentation.Create` 集中决定资源路径与提示：任务栏为浅色时用深色字标、深色任务栏用白色字标；未开启记录与手动暂停共用 `-paused` 资源；提示分别追加“· 未开启记录”“· 已暂停记录”，正常态不追加后缀。
- `TrayIconImages` 按（资源, 尺寸）缓存 HICON，用 `CreateIconFromResourceEx` 从 ICO 中挑出的单帧创建，不使用 `LR_SHARED`，释放时显式 `DestroyIcon`；读取失败也缓存，避免每次通知重开资源。读取失败回退到 EXE 内嵌图标，再回退系统默认图标。
- `TrayIconFrames.Select` 只把 ICO 目录中最合适的一帧交给 user32（精确尺寸优先，其次优先下采样而不放大），并跳过越界/截断目录项。
- 图标尺寸取主任务栏 `Shell_TrayWnd` 的 DPI 下 `SM_CXSMICON`，隐藏的托盘窗口自身不跟随任务栏移动；未提供 `SystemUsesLightTheme` 时按经典深色任务栏处理，高对比模式改用系统窗口配色判断。
- 响应 `TaskbarCreated`、`WM_SETTINGCHANGE`、`WM_SYSCOLORCHANGE`、`WM_THEMECHANGED`、`WM_DISPLAYCHANGE`、`WM_DPICHANGED`，合并为一次延迟刷新；仅在图标或提示实际变化时才 `NIM_MODIFY`。
- 浮层里的 `StateChanged` 事件与 `UpdateTrayTooltip` 已删除，改由 `App` 订阅 `LibraryViewModel.PropertyChanged`（`RecordingEnabled` / `Paused` / `ShortcutDisplay`）驱动；`ShortcutDisplay` 改变不再依赖浮层是否创建过。

### 自动化验证

- `windows/build.ps1 -SkipPublish`：Release 构建 **0 警告、0 错误**。
- `CvMaster.SmokeTests`：**ALL PASS (155 checks)**，含新增 11 项托盘检查（`--tray-only` 可单独重跑，本机结果 `ALL PASS (11 checks)`）：
  - 浅色 / 深色任务栏各 3 项：字标取反色、未开启与暂停使用同一资源、提示保留快捷键并区分两种非记录状态；
  - ICO 帧选择 5 项：150% DPI 精确匹配、缺少精确尺寸时优先下采样、目录 0 尺寸代表 256、拒绝截断目录、跳过偏移越界帧。
- `python -I windows/tools/check-icons.py`：`PASS: shared SVG, app assets, two unchanged-size states, and four nine-size tray icons`。校验共享 SVG 几何（`app-mark`/`status-mark`/`pause-mark`）、两端 PNG 主图一致、ICNS 标准与 Retina 帧、四份 ICO 的九个尺寸、明暗两套形状透明度一致、暂停标记确实是两条分离竖条、四个托盘资源已嵌入 csproj。
- `dotnet format cvMaster.slnx --verify-no-changes --include <本次改动文件>`：10/10 无差异。仓库另有 46 个历史文件在工作区为 CRLF（`.gitattributes` 要求 LF，`core.autocrlf=true` 导致），`--verify-no-changes` 全量运行会报 3720 条 `ENDOFLINE`；本次提交未触及这些文件，属于既有环境差异，不是本轮回归。

### Windows 实机交互验证（本机 Windows 11 build 26300、x64、125% DPI、浅色任务栏）

用 `bin/Release` 产物启动，通过 UI Automation 读取托盘元素名称与截图核对字形：

| 状态 | 图标 | 悬停提示 | 判定 |
| --- | --- | --- | --- |
| 记录开启、未暂停 | 深色 CV，无附加标记 | `cvMaster · Alt+Space` | 通过 |
| 手动暂停（更多操作 → 暂停记录） | CV + 右下双竖条 | `cvMaster · Alt+Space · 已暂停记录` | 通过 |
| 关闭记录（设置页「允许记录剪贴板」） | CV + 双竖条（与暂停同一资源） | `cvMaster · Alt+Space · 未开启记录` | 通过 |

- 浅色任务栏下字标为深色单色（实测字形像素集中在 `#161616` 附近，无彩色边缘），符合“与任务栏相反色”的设计；暂停标记实测为 CV 右下两条分离竖条。
- 三种状态切换均在一次运行内即时生效，无需重启：暂停由浮层菜单触发、关闭记录由设置页开关触发，图标与提示随之更新。
- 状态持久化一致：暂停写 `Paused=1`、恢复写 `Paused=0`，记录开关写 `RecordingEnabled`，与图标表现同步。

### 未覆盖项

- 深色任务栏（`SystemUsesLightTheme=0`）本轮未切换主题实测，仅由 `TrayChecks` 与 `check-icons.py` 覆盖资源选择与白色字标形状；高对比模式同样未实机验证。
- 任务栏位置变化、混合 DPI 多显示器、`WM_DPICHANGED` 与 Explorer 重启（`TaskbarCreated`）未在本轮触发实测。
- macOS 端本次同步改动为 SwiftUI/AppKit（`StatusIconPresentation.swift`、`ChecksStatusIcon.swift` 等），本机无 Swift 工具链，未编译运行。

### 环境恢复

- 测试实例已退出，`RecordingEnabled=1`、`Paused=0` 恢复为验证前状态，`OnboardingShown=1` 保留；历史仍为 0 条（`entry`/`user_group`/`entry_group`/`representation` 全为 0）。
- 未执行部署脚本，未安装或卸载应用，未改动 `%LOCALAPPDATA%\Programs\cvMaster` 中的既有安装；未修改、未提交任何仓库文件（本节除外）。
- 本机 `dotnet` 不在 `PATH`，且 `C:\Program Files\dotnet` 只有运行时没有 SDK；构建时把 `%LOCALAPPDATA%\Microsoft\dotnet` 前置到 `PATH`（该目录含 SDK 10.0.402）。`build.ps1` 的 `Resolve-DotNet` 会优先命中 `Get-Command dotnet`，因此在 `Program Files` 安装 SDK 或调整 PATH 顺序前，直接运行脚本会失败。

## 19. 首个 Windows 安装包（2026-11-26）

首次产出 Windows 安装包并发布到 GitHub Releases。版本从 `v0.1.0`（tag 在 `0f4f78d`）升到 `v0.1.1`，因为当前 HEAD 比 tag 多 4 个提交（IM 文件路径三级回退、双平台状态图标）。

### 版本与打包配置

- `src/CvMaster/CvMaster.csproj`：`Version` / `FileVersion` 从 `0.1.0` / `0.1.0.0` 改为 `0.1.1` / `0.1.1.0`。
- `packaging/cvMaster.iss`：`AppVersion` / `VersionInfoVersion` 同步为 `0.1.1` / `0.1.1.0`。
- 安装包沿用既有配置：`PrivilegesRequired=lowest`、`DefaultDirName={localappdata}\Programs\cvMaster`、`ArchitecturesAllowed=x64compatible`、LZMA2 ultra64、简体中文向导、`AppMutex=Local\cvMaster.Instance`、卸载跳过用户数据目录。
- 打包工具：Inno Setup 6.7.3，`winget` 装在用户目录 `%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`（不是 `Program Files (x86)`，脚本查找时注意）。

### 构建与产物

| 项目 | 结果 |
| --- | --- |
| `build.ps1`（Release + 冒烟 + 自包含发布） | `ALL PASS (155 checks)`，0 警告、0 错误 |
| 发布产物 | `dist/win-x64/`，134.5 MB，`cvMaster.exe` FileVersion `0.1.1.0` |
| ProductVersion | `0.1.1+0d7166fc8eadf839a05d8198210f406b5f12558d`（带提交号） |
| 安装包 | `dist/installer/cvMaster-Setup-0.1.1.exe`，43.67 MB |
| 安装包 SHA-256 | `10e04413a42c75b20adceb0bc78cc7515e71b0ef45555e904fad972e9b531438` |

### 安装包实测

静默安装（`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`）：

- 退出码 0；装到 `%LOCALAPPDATA%\Programs\cvMaster`，251 个文件。
- `cvMaster.exe` FileVersion 变为 `0.1.1.0`，覆盖升级了原有的 0.1.0 安装。
- 开始菜单快捷方式 `cvMaster.lnk` 创建成功；卸载项 `cvMaster (当前用户) 0.1.1` 注册到 `HKCU`。
- 启动后进程存活且 `Responding=True`，`%LOCALAPPDATA%\cvMaster\logs` 记录 `startup` 无错误。
- 托盘图标确认打包在程序集内：安装目录没有独立 `tray-*.ico` 文件，符合“单文件发布不需旁置图标”的设计。
- 用户数据未被改动，`history.sqlite` 保持 0 条记录。

静默卸载：

- 退出码 0；开始菜单快捷方式与 `HKCU` 卸载项均已移除；`%LOCALAPPDATA%\cvMaster` 中的历史与设置保留（符合设计）。
- 残留两个空目录 `Programs\cvMaster\Assets` 与 `Programs\cvMaster\zh-Hans`，不含任何文件。这是 Inno Setup 对空子目录的已知行为，不影响后续重装。

### 未覆盖项

- 未验证图形化安装向导的界面与文案（使用静默模式），也未验证「创建桌面快捷方式」勾选项与 `/DIR=` 自定义安装目录。
- 本次静默安装实际落到默认目录而非传入的 `/DIR=`：PowerShell `Start-Process` 的数组传参把 `/DIR=` 和路径拆成了两个参数。后续验证自定义目录应改用 `-ArgumentList '/DIR="<路径>"'` 单字符串形式。
- 安装包未做 Authenticode 代码签名，SmartScreen 拦截提示未实测截图。
- arm64 安装包未构建（`ArchitecturesAllowed=x64compatible`，需另配）。
- 安装覆盖了本机原有的 0.1.0 安装，卸载后未重新安装；`%LOCALAPPDATA%\Programs\cvMaster` 现仅剩两个空目录。
