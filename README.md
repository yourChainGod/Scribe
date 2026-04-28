# Scribe

> A native macOS text editor inheriting the spirit of [notepad--](https://gitee.com/cxasm/notepad--), reborn in SwiftUI.

[![CI](https://github.com/yourChainGod/Scribe/actions/workflows/ci.yml/badge.svg)](https://github.com/yourChainGod/Scribe/actions/workflows/ci.yml)
&nbsp;
![macOS 14+](https://img.shields.io/badge/macOS-14.0+-blue)
&nbsp;
![Swift 6](https://img.shields.io/badge/Swift-6%20strict-orange)
&nbsp;
![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-green)

Scribe 是一款 **macOS 原生** 文本与代码编辑器。SwiftUI 主壳 + Scintilla 编辑核心 + 全本地化（English / 简体中文）。目标是补齐 macOS 上「轻量、快、好看、能用」的那一格——既不是 VS Code 的全功能 IDE，也不是 TextEdit 的极简，而是介于两者之间、原生气质的 daily driver。

---

## ✨ Features

### 编辑核心
- **Scintilla 5.6.1 + Lexilla 5.4.5**：成熟的语法高亮、折叠、缩进引导。
- **多光标 / 多选区**：⌘D 渐选下一个、⌥⌘↑/↓ 垂直堆光标、⌘⇧L 选中所有匹配。
- **列（矩形）选择**：⌘⇧8 切换矩形选择模式。
- **8 套主题**：System / Light Default / Dark Default / Solarized Light · Dark / Dracula / Monokai / GitHub Light，跟随系统外观切换。
- **8 种语言 lexer**：Swift / C++ / Python / JavaScript / TypeScript / Markdown / JSON / Shell + 自动后缀检测，可在状态栏覆盖。

### 工作区
- **多标签 + 文件树侧栏**：⌘1/⌘2 切 Files / Outline 模式。
- **Quick Open（⌘P）**：模糊匹配工作区文件。
- **Command Palette（⌘⇧P）**：所有菜单项指令、热键提示一处搜索。
- **Find（⌘F）/ Find-in-Files（⌘⇧F）**：含 Match Case / Whole Word / Regex；Find-in-Files 支持 include / exclude glob、批量替换、行级排除。
- **Diff View**：左右双栏 hunk 高亮、滚动同步。

### 文件 IO
- **编码自动检测**：BOM → UTF-8 严格 → GB18030 → Big5 → Shift-JIS 启发式链。
- **行尾自动归一**：LF / CRLF / CR 三选一，状态栏可手动切换。
- **FSEvents 监听**：磁盘变更自动提示重载或保留。
- **异步打开**：20 MB 文件不卡 UI（Phase 28b——主线程同步部分恒定 < 5 ms）。
- **节流编辑**：50 MB 文件 typing 不卡 — SCN_MODIFIED 50 ms debounce（Phase 28c）。
- **Markdown 预览**：⌘⇧V 在右侧 split 预览 .md 文件，所见即所得，WKWebView 渲染（Phase 30）。支持 GFM 表格 / task list `[ ] [x]` / footnote `[^id]`（Phase 32）。
- **Git Gutter**：左侧窄 margin 画【+】【·】【—】三色纹显示相对 HEAD 的加/改/删行，保存后自动刷新（Phase 31）。⌥⇧↓ / ⌥⇧↑ 跳下一/上一个变更块（Phase 31b）。
- **代码片段（Snippets）**：⌘⇧T 弹出 fuzzy 选择器（复用 Command Palette），在当前光标（多光标下多点）插入 body。设置 → 代码片段 tab 增/删/改，输入即存 UserDefaults JSON（Phase 33）。

### 完整本地化
- **English / 简体中文** 双语包，203 个 key 全覆盖。
- 启动语言跟随系统 `AppleLanguages`，可通过 `defaults write` 强制指定。

### 工程化
- **零外部 SwiftPM 依赖**。Vendor 中只有 Scintilla + Lexilla（GPL-2 兼容 GPL-3）。
- **Swift 6 strict concurrency** 全绿，0 error / 0 warning（Vendor/scintilla 除外）。
- **CI 四道闸**：`swift test` · `swift build -c release` · `swift build -swift-version 6` · Localizable strings 校验。
- **191 个单元测试** 含 Theme / Lexer / TextFormat / Find-in-Files / Performance / DocumentFlush / MarkdownConverter / GitDiffParser / GitGutterHunks / SnippetCatalog。

---

## 🚀 Quick Start

### 从源码运行
```bash
git clone https://github.com/yourChainGod/Scribe.git
cd Scribe
swift run Scribe
```

要求 macOS 14 (Sonoma) +、Xcode 15.3+、Swift 6 工具链。

### 打 .app 包
```bash
bash Scripts/build_app.sh
open build/Scribe.app
```

`build_app.sh` 会跑 release build、嵌入 Info.plist + Localizable bundle + AppIcon、产出可双击运行的 `Scribe.app`。

### 打开任意文件 / 文件夹（命令行）
```bash
# 单文件
open -a build/Scribe.app /path/to/file.swift

# 文件夹（侧栏自动展开）
SCRIBE_AUTO_FOLDER=/path/to/project swift run Scribe

# Diff 两个文件
SCRIBE_AUTO_COMPARE=/path/a.txt:/path/b.txt swift run Scribe
```

---

## ⌨️ Cheat Sheet

| 类别 | 快捷键 | 说明 |
|---|---|---|
| **导航** | `⌘P` | Quick Open（工作区文件模糊搜索） |
| | `⌘⇧P` | Command Palette |
| | `⌘1` / `⌘2` | 切换 Files / Outline 侧栏 |
| | `⌘⇧O` | 跳转到符号 |
| | `⌃G` | 跳转到行 |
| **编辑** | `⌘D` | 选中下一个匹配 |
| | `⌃⌘D` | 跳过当前并选中下一个 |
| | `⌘⇧L` | 选中所有匹配 |
| | `⌥⌘↑` / `⌥⌘↓` | 在上 / 下方添加光标 |
| | `⌘⇧8` | 切换列（矩形）选择 |
| | `⌥↑` / `⌥↓` | 上 / 下移行 |
| | `⌘⇧K` | 删除当前行 |
| | `⌘/` | 切换行注释 |
| **查找** | `⌘F` | 当前文件查找 |
| | `⌘⇧F` | 整个工作区查找 |
| | `⌘G` / `⌘⇧G` | 下一个 / 上一个匹配 |
| | `⌘⌥F` | 替换 |
| **文件** | `⌘N` | 新建标签 |
| | `⌘O` | 打开文件 |
| | `⌘⇧O` | 打开文件夹 |
| | `⌘W` | 关闭标签 |
| | `⌘S` | 保存 |
| | `⌘⇧S` | 另存为 |

完整列表见菜单栏 **View → Command Palette**。

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────┐
│  SwiftUI Scene                                  │
│  ScribeApp · ScribeCommands · MainWindow        │
└─────────────────────────────────────────────────┘
                  │ @StateObject graph
                  ↓
┌─────────────────────────────────────────────────┐
│  Models                                         │
│  Workspace · Document · EditorPreferences       │
│  FindState · FindInFilesEngine · ThemeManager   │
│  FileIndex · SymbolOutline · DirectoryWatcher   │
└─────────────────────────────────────────────────┘
                  │ NSViewRepresentable
                  ↓
┌─────────────────────────────────────────────────┐
│  ScintillaCodeEditor (Coordinator)              │
│  ↳ Scintilla 5.6.1 + Lexilla 5.4.5  (Vendor/)   │
└─────────────────────────────────────────────────┘
```

每一层的职责切得很干净：

- **App 层** (`Sources/Scribe/App/`)
  - `ScribeApp.swift` — Scene declaration（< 150 行）
  - `AppCommands.swift` — 整个菜单栏（File / Edit / View / Go / Tools）
  - `StartupEnvironment.swift` — `SCRIBE_AUTO_*` 环境变量解析
  - `TestHooks.swift` — `SCRIBE_TEST_*` 自动化截图钩子

- **Models 层** (`Sources/Scribe/Models/`)
  - 全部 `@MainActor`，纯 Swift，零 AppKit 依赖（除 NSAlert）。
  - I/O 通过 `Task.detached` 跑后台，主线程仅做 placeholder + 应用结果。

- **Views 层** (`Sources/Scribe/Views/`)
  - SwiftUI 视图为主；唯一 NSViewRepresentable 是 ScintillaCodeEditor。
  - `Scintilla/SCIConstants.swift` 集中所有 `SCI_*` / `SCN_*` 数值常量。

---

## 🌍 Internationalization

Scribe 自带 `en` 与 `zh-Hans` 资源包（203 个 key 全覆盖），由 SwiftPM `.process("Resources")` 注入到 Bundle.module。

- **选择语言**：跟随 `~/Library/Preferences/.GlobalPreferences.plist` 的 `AppleLanguages`。
- **强制中文**：
  ```bash
  defaults write org.scribe.editor AppleLanguages '(zh-Hans, en)'
  open build/Scribe.app
  ```
- **新增语言**：复制 `Sources/Scribe/Resources/en.lproj/` 为 `xx-YY.lproj/`，翻译 `Localizable.strings`。CI 会校验 key 集合一致。

---

## 🛠️ Development

### 测试
```bash
swift test                              # 全部 110 个 case
swift test --filter ThemeCatalogTests   # 单测目标
swift test --filter PerformanceTests    # 1MB / 5MB / 20MB 性能预算
```

性能 fixture 不入库，跑前先：
```bash
bash Scripts/gen_perf_samples.sh
```

### Swift 6 严格并发
```bash
swift build -Xswiftc -swift-version -Xswiftc 6
```
保持 0 error / 0 warning（Vendor/ 除外）。

### Localizable strings 校验
```bash
swift Scripts/check_localization.swift
```
检查 en ↔ zh-Hans key 同步、源代码无 dangling reference。

### 自动化截图
所有 `SCRIBE_TEST_*` 环境变量在 `Sources/Scribe/App/TestHooks.swift`，每个钩子文档化了它驱动的 UI 状态。

---

## 🗺️ Roadmap

详见 [ROADMAP.md](ROADMAP.md)。

当前状态：
- ✅ Phase 0–17：UI 骨架、Scintilla 上屏、编码 / 行尾、查找替换、行级 replace、字号 / 主题
- ✅ Phase 18–24：multi-cursor、column select、菜单分组
- ✅ Phase 25–26：UI polish 全套、app icon
- ✅ Phase 27：i18n
- ✅ Phase 28：Swift 6 strict + 架构拆分
- ✅ Phase 28b：异步 openFile + 性能预算
- ✅ Phase 28c：SCN_MODIFIED 50 ms 节流（typing 不卡）
- ✅ Phase 28d：Coordinator 拆分（主文件 1083 → 385 行）
- ✅ Phase 29：CI lockstep + 文档同步
- ✅ Phase 30：Markdown 实时预览（手写转换器 + WKWebView，零依赖）
- ✅ Phase 31：Git Gutter（unified-diff parser + Scintilla margin，零依赖）
- ✅ Phase 31b：Git Gutter Hunk 跳转（⌥⇧↑/↓，环绕换行）
- ✅ Phase 32：Markdown Preview v2（GFM 表格 · task list · footnote，零依赖）
- ✅ Phase 33：Snippets v1（⌘⇧T 选择器 + Settings 管理 tab，UserDefaults JSON）
- 🔜 Phase 34+：ndd C++ core / Document Map / Snippets v2 / Markdown Preview v3 / HEX View / Sparkle

---

## 📜 License

**GPL-3.0** — see [LICENSE](LICENSE).

与上游 [`notepad--`](https://gitee.com/cxasm/notepad--) 对齐。Phase 2+ 计划移植 ndd 的 C++ 核心（`Encode.cpp`、`CmpareMode.cpp`、HEX view），其本身 GPL-3.0；按 copyleft，全项目继续 GPL-3.0。

Vendor:

- **Scintilla 5.6.1** — Histogram License（与 GPL 兼容），© 1998–2024 Neil Hodgson
- **Lexilla 5.4.5** — Histogram License，© Neil Hodgson 等

---

## 🙏 Credits

- [`notepad--`](https://gitee.com/cxasm/notepad--) by **cxasm** — 设计灵感与算法源头
- [Scintilla](https://www.scintilla.org/) by **Neil Hodgson** — 编辑核心
- [`notepad-plus-plus-mac`](https://github.com/notepad-plus-plus-mac/notepad-plus-plus-macos) — 拓扑参考
