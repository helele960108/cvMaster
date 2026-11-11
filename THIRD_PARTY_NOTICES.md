# 第三方组件与素材声明

本文件记录 cvMaster 源码仓库中直接引用、打包或随发布产物分发的第三方组件。
项目自身以 [Apache License 2.0](LICENSE) 发布；下列组件仍受各自许可证约束。

## 运行时依赖

### Microsoft.Data.Sqlite 10.0.13

- 用途：Windows 版的 SQLite ADO.NET 提供程序。
- 许可证：MIT
- 版权：Copyright © Microsoft Corporation.
- 来源：https://learn.microsoft.com/dotnet/standard/data/sqlite/

### SQLitePCLRaw 2.1.13

- 组件：`SQLitePCLRaw.bundle_e_sqlite3`、`SQLitePCLRaw.core`、
  `SQLitePCLRaw.lib.e_sqlite3`（`Microsoft.Data.Sqlite` 的传递依赖）。
- 用途：Windows 版 SQLite 原生绑定。
- 许可证：Apache-2.0
- 版权：Copyright 2014-2024 SourceGear, LLC.
- 来源：https://github.com/ericsink/SQLitePCL.raw

### SQLite

- 用途：本地历史数据库；macOS 使用系统 SQLite3，Windows 通过 SQLitePCLRaw 使用内置
  SQLite。
- 许可证：SQLite 源码已放入公有领域（public domain）。
- 来源：https://www.sqlite.org/

### .NET Runtime

- 用途：仅在 Windows 自包含发布时随产物分发。
- 许可证：MIT
- 版权：Copyright © .NET Foundation and Contributors.
- 来源：https://github.com/dotnet/runtime

## 构建与打包工具

### Inno Setup 简体中文语言文件

- 文件：`windows/packaging/languages/ChineseSimplified.isl`
- 用途：仅在构建 Windows 安装包时使用，不属于应用运行时。
- 许可证：MIT
- 版权：Copyright © Zhenghan Yang (Kira) 及贡献者。
- 来源：https://github.com/kira-96/Inno-Setup-Chinese-Simplified-Translation

### Pillow

- 用途：`windows/tools/generate-icon.py` 的可选构建工具依赖，不随应用分发。
- 许可证：MIT-CMU
- 来源：https://python-pillow.org/

## 设计素材

### 应用图标

`native/Resources/` 与 `windows/src/CvMaster/Assets/` 中的图标由项目维护者提供并用于本项目。若后续替换为第三方素材，应在合并前补充来源、作者和许可证。

### 字体

界面使用操作系统自带字体（如 SF Pro、苹方、Microsoft YaHei），仓库不分发字体文件。

## MIT 许可证文本

以下文本适用于本文件中标注为 MIT 的第三方组件：

```text
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Apache-2.0 组件的完整许可证文本见仓库根目录的 [LICENSE](LICENSE)。
