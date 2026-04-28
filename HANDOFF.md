# Scribe 交接文档

> **Last session**: 2026-04-28（接力第二夜，Phase 1.7a 落地）
> **Phase reached**: 1.7a (ScintillaView 在 GUI 真实渲染，单向数据流通)
> **Status**: ✅ 可双击运行 · ✅ 编码/行尾全支持 · ✅ Scintilla 真上屏（SCRIBE_USE_SCINTILLA=1 + SCRIBE_AUTO_OPEN）· 🔜 下次反向同步 + 主题/光标/软 Tab

## 0. 这一夜的接力记录（2026-04-28）

六件事一气干完：

| 阶段 | 提交 | 内容 |
|------|------|------|
| **D · 杂事清理** | `971f1fc` | git init 打基线（首次 commit） + LICENSE 拷自 ndd（GPL-3.0）+ README 写明 License + .gitignore 加 build/ |
| **B · Phase 0.2 细节** | `19f524c` | 新增 `EditorPreferences`（持久化）· 字号 ⌘+/⌘-/⌘0 · 工具栏字号读数 · 最近文件菜单（10 项）· 软 Tab + Tab 宽度 · 状态栏 `Ln/Col` 实时回填 · 设置面板真正可用（字体/字号/Tab/清除最近） |
| **C · Phase 0.3 编码与行尾** | `aef0b34` | 新增 `TextFormat.swift` 启发式检测器（BOM → 严格 UTF-8 → GB18030 → Big5 → Shift-JIS）· 状态栏编码/行尾改 Menu（`Reopen with…` / `Save with…`）· `Workspace.reopen(doc:as:)` · ScribeTests target + 15 个单测全绿 |
| **文档** | `d331157` | HANDOFF + ROADMAP 全面刷新，加 ADR-003 |
| **A · Phase 1.0 Scintilla 接通** | `cc283b4` | 拉 Scintilla 5.6.1 到 Vendor/ · 自添 `include/module.modulemap` + `ScribeScintillaUmbrella.h` · Package.swift 加 cxx17 target · `swift build` 全过 · `swift test` 17/17（含 2 个 bridge 测）· Scribe 启动不崩 · runtime GUI 嵌入留下次 |
| **文档 2** | `7802d44` | HANDOFF + ROADMAP 记 Phase 1.0 进展，ADR-003 标记完结 |
| **A · Phase 1.7a Scintilla 上屏** | `2a184a9` | 新增 `ScintillaCodeEditor.swift` SwiftUI 桥 · `EditorAreaView` 加 `SCRIBE_USE_SCINTILLA=1` 切换 · `ScribeApp` 加 `SCRIBE_AUTO_OPEN` env var（避开 SwiftUI WindowGroup 不接受 argv 的坑）· `Workspace.init(prefs:openInitialUntitled:)` 让调用方可选不开 Untitled · **screenshot 实锤**：Scintilla 渲染 Swift 代码 + 中文/韩文/日文注释 + 状态栏 299 chars |

**License 锁定**：GPL-3.0。原因不可逆——ROADMAP ADR-002 要求 Phase 2+ 移植 ndd C++ 核心 (`Encode.cpp` / `CmpareMode.cpp` / HEX)，这些是 GPL-3.0，传染性使 Scribe 必须同 license。MIT/Apache 已无可能。

**License 演进**：本仓库遵循 GPL-3.0。`Models/TextFormat.swift` 的启发式策略借鉴 ndd `src/Encode.cpp:203/346` 的判断顺序但完全 Swift 重写，无源码层 import。

---

## 1. 项目背景（30 秒读完）

**Scribe** 是一个 macOS 原生文本编辑器，目标取代 [notepad--](https://gitee.com/cxasm/notepad--) 在 Mac 上的角色，
但完全脱离 Qt，用 SwiftUI + AppKit 重构。

**核心决策**：
- 抛 Qt5 / Qt6 / QML — 美学上限低
- 仅 macOS — 放弃跨平台，换取原生质感
- UI 全新写，业务核心未来从 ndd C++ 移植（**尚未开始**）

**项目位置**：
```
/Users/zhangshijie/Documents/Project/Scribe/             ← Scribe 工程根
/Users/zhangshijie/Documents/Project/notpad--/notepad--/ ← 原 ndd，已 cmake 编译过
```

---

## 2. 一分钟跑起来

```bash
cd /Users/zhangshijie/Documents/Project/Scribe

# 方式 A：开发模式（最快迭代）
swift run Scribe

# 方式 B：打包成 .app（用户态体验）
./Scripts/build_app.sh release
open build/Scribe.app

# 方式 C：用 .app 打开指定文件
open -a build/Scribe.app /tmp/some.txt
```

**依赖**：Xcode 15+ / Swift 6+ / macOS 13+。当前机器 Xcode 26.3、Swift 6.2.4，已验证可编译。

---

## 3. 当前能力清单

### ✅ 已实现

**Phase 0.1（首夜基线）**

| 能力 | 实现位置 |
|------|---------|
| 多标签管理（新建 ⌘N / 打开 ⌘O / 保存 ⌘S） | `Models/Workspace.swift` |
| 文件读写（NSOpenPanel / NSSavePanel） | `Workspace.openFile / saveCurrent` |
| 关闭未保存提示（Save / Don't Save / Cancel） | `Workspace.close(documentID:)` |
| 拖放打开文件 / 文件夹 | `Views/MainWindow.swift` `.onDrop` |
| 侧栏：OPEN 列表 + WORKSPACE 文件树 | `Views/SidebarView.swift` |
| 文件树（懒加载、可展开） | `Models/FileNode.swift` + `Views/FileTreeView.swift` |
| 标签页（圆角 + 蓝色顶边 + 关闭按钮） | `Views/TabBarView.swift` |
| 编辑器（NSTextView + 行号 ruler + 等宽字体） | `Views/CodeEditor.swift` |
| 状态栏（语言/编码/行尾/字符数/dirty） | `Views/StatusBarView.swift` |
| 工具栏（SF Symbols 图标） | `Views/MainWindow.swift` `.toolbar` |
| 暗色主题（系统级跟随，0 行代码） | 自动 |
| 应用图标 / .app bundle | `Scripts/build_app.sh` + `Resources/icon.svg` |
| `open file.txt` 打开外部文件 | `ScribeApp.swift` `.onOpenURL` |

**Phase 0.2（接力夜 · 偏好与产品手感）**

| 能力 | 实现位置 |
|------|---------|
| `EditorPreferences` 持久化（fontSize/fontName/tabWidth/softTabs/recentFiles） | `Models/EditorPreferences.swift` |
| 字号 ⌘+/⌘-/⌘0 + 工具栏字号读数 | `ScribeApp.swift` `.commands` + `MainWindow.toolbar` |
| 最近文件菜单（File → Open Recent，10 项 + Clear） | `ScribeApp.RecentFilesMenu` |
| 软 Tab：按 Tab 插入 N 空格（可关） | `CodeEditor.Coordinator.textView(_:doCommandBy:)` |
| Tab 宽度（`paragraphStyle.defaultTabInterval`） | `CodeEditor.paragraphStyle` |
| 状态栏 `Ln/Col` 实时回填（`textViewDidChangeSelection`） | `Document.cursorLine/Column` + `CodeEditor.Coordinator.syncCursorPosition` |
| 设置面板真正可用（字体族/字号/Tab/清除最近） | `Views/SettingsView.swift` |

**Phase 0.3（接力夜 · 编码与行尾）**

| 能力 | 实现位置 |
|------|---------|
| 启发式编码检测：BOM → 严格 UTF-8 → GB18030 → Big5 → Shift-JIS | `TextFormatDetector.sniffEncoding` |
| 严格 UTF-8 字节验证（RFC 3629 长度+续位） | `TextFormatDetector.isValidUTF8` |
| 行尾自动检测（CRLF/CR/LF，按 scalar 计数避开 grapheme 陷阱） | `TextFormatDetector.detectLineEnding` |
| 行尾归一/还原（内存 LF，磁盘按 `Document.lineEnding`） | `normalize/denormalize` |
| BOM 写入（保存时按 `TextEncoding.bomBytes` 前缀注入） | `TextFormatDetector.encode` |
| 状态栏编码/行尾 Menu（Reopen with… / Save with…） | `StatusBarView.encodingMenu` |
| `Workspace.reopen(doc:as:)`（脏文档前确认） | `Models/Workspace.swift` |
| 单测：15 个，覆盖 BOM/UTF-8/GBK/三种行尾/round-trip/grapheme 陷阱 | `Tests/ScribeTests/TextFormatTests.swift` |

### ❌ 尚未实现 / 已知不足

- 编辑器主区仍是 **NSTextView**（无语法高亮、无折叠、大文件性能未验证）— Phase 1 待决策
- 自定义查找替换面板（NSTextView 自带 Find Bar 已可用，⌘F 触发）— 推后到 Phase 1 内核换完后一起重做
- 文件比较（ndd 招牌功能，Phase 4）
- HEX 模式（Phase 5）
- 应用图标 .icns 当前用 qlmanage fallback 生成，质量一般 — 装 `brew install librsvg` 后会更锐利
- `EditorPreferences.fontName` 已联动 NSFont 但若用户选了不存在的字体会回退系统等宽（无错误提示）

---

## 4. 文件结构地图

```
Scribe/
├── README.md                    ← 派门简介
├── ROADMAP.md                   ← 完整路线图 + ADR（含 ADR-003 编辑器内核选择）
├── HANDOFF.md                   ← 本文件
├── LICENSE                      ← GPL-3.0
├── Package.swift                ← SwiftPM manifest（macOS 13+, exe + tests）
├── .gitignore                   ← 含 build/ 与 Vendor/*/build/
├── Resources/
│   └── icon.svg                 ← 应用图标源（"S" 渐变）
├── Scripts/
│   └── build_app.sh             ← 一键打包 .app（生成 Info.plist + .icns）
├── build/                       ← 产物（已 gitignore）
│   └── Scribe.app
├── Sources/Scribe/
│   ├── ScribeApp.swift          ← @main + 激活策略 + 菜单 + Open Recent + 字号快捷键
│   ├── Models/
│   │   ├── Document.swift       ← 单标签数据（text/encoding/lineEnding/cursorLine/cursorColumn）
│   │   ├── Workspace.swift      ← 全局状态 + openFile/reopen/setEncoding/setLineEnding
│   │   ├── FileNode.swift       ← 文件树节点（懒加载子目录）
│   │   ├── EditorPreferences.swift  ← ⭐ 持久化偏好（字号/字体族/Tab/软Tab/最近文件）
│   │   └── TextFormat.swift     ← ⭐ 编码检测器 + LineEnding + TextEncoding enum
│   └── Views/
│       ├── MainWindow.swift     ← NavigationSplitView + 工具栏（字号 +/-）+ 拖放
│       ├── SidebarView.swift    ← OPEN + WORKSPACE 两段式侧栏
│       ├── TabBarView.swift     ← 标签条
│       ├── EditorAreaView.swift ← 编辑区路由（含 Welcome 引导页）
│       ├── CodeEditor.swift     ← ⭐ NSTextView 桥 + LineNumberRuler + softTab + 光标回填
│       ├── FileTreeView.swift   ← 递归文件树
│       ├── StatusBarView.swift  ← 底部状态栏（编码/行尾 Menu + Ln/Col）
│       └── SettingsView.swift   ← 设置面板（字体/字号/Tab/清除最近 + About）
└── Tests/ScribeTests/
    └── TextFormatTests.swift    ← 15 个单测：BOM/UTF-8/GBK/行尾/round-trip
```

**代码量**：1856 行 Swift（15 个源文件 + 1 个测试文件 = 16 个）。

---

## 5. 关键技术决策（必读，避免下次走弯路）

### 5.1 为什么选 SwiftPM 而非 Xcode 工程？

- **优**：纯文本可读、易 git diff、命令行 `swift build/run` 极快
- **劣**：默认不生成 .app bundle，需手动 `Scripts/build_app.sh`
- **重要技巧**：`ScribeApp.init()` 里调用 `NSApplication.shared.setActivationPolicy(.regular)`
  否则 SwiftPM executable 默认是后台进程，**窗口不会显示**

### 5.2 为什么编辑器先用 NSTextView 而非直接上 Scintilla？

- Scintilla 集成需 ~5-8h（Cocoa 端口 + Objective-C++ 桥 + lexer 配置），**这次会话装不下**
- NSTextView 已能撑 Phase 0.1 的演示需求（行号 / 等宽字体 / 暗色 / 撤销 / 系统查找）
- `CodeEditor` 是 `NSViewRepresentable`，**未来切 Scintilla 时只换底层 NSView，外层 API 不动**

### 5.3 为什么 Document / Workspace 用 `@MainActor`，FileNode 不用？

- Swift 6 严格并发：`Identifiable` 协议要求 `id` 可在任意 actor 访问
- `FileNode` 因此用 `@unchecked Sendable` + `nonisolated id`，避开严格隔离
- 实际所有读写仍在主线程（SwiftUI 视图回调）

### 5.4 为什么 SourceKit 在编辑期间报一堆 "Cannot find type 'Document'"？

- **可忽略** — 这是 IDE 静态解析滞后，`swift build` 是模块级整体编译，能看到所有类型
- 验证方法：每次改完跑 `swift build`，能 `Build complete!` 就 OK

### 5.5 为什么 `Coordinator.syncCursorPosition` 必须显式 `@MainActor`？

`Coordinator` 是 NSObject + NSTextViewDelegate。Swift 6 严格并发下，**协议方法**
（如 `textDidChange`/`textViewDidChangeSelection`）会自动继承 NSTextViewDelegate
的隔离上下文（在 main actor 上）。但**自定义 helper 方法**不会自动继承——
访问 `@MainActor` 的 `Document.cursorLine/Column` 会编译失败。
解决：在 helper 上显式标 `@MainActor`。详见 `CodeEditor.swift:165`。

### 5.6 为什么 `detectLineEnding` 不能用 `for ch in text`？

Swift 把 `"\r\n"` 当作**单个 Character**（扩展字形簇 grapheme cluster），
所以 `for ch in "a\r\nb"` 看到的是 `[a, "\r\n", b]` —— `\r` 和 `\n` 都不会
单独出现，CRLF 计数永远是 0。必须改用 `text.unicodeScalars` 才能拆开。
单测 `testDetectCRLF` 锁住这个行为。

### 5.7 为什么 Scribe 不能用 `swift run Scribe foo.txt`？

SwiftUI 的 `WindowGroup` 在 SwiftPM unbundled 二进制下，**只要 argv 里有任何
非选项位置参数，就会拒绝实例化主 NSWindow**——它把这视为 NSDocument 风格的
"open document" 意图，等待一个永远不到的 NSDocumentController 事件。
现象：进程活着、`@StateObject` 完整、`body` 求值正常，但 `NSApp.windows == []`。
真相是 SwiftPM 出来的 binary 没注册 NSDocument 类型，那个事件就不会被派发。

**workaround**（已落地于 `cc283b4` → `2a184a9`）：
- `ScribeApp.init` **不读** `CommandLine.arguments`
- 改用 `ProcessInfo.processInfo.environment["SCRIBE_AUTO_OPEN"]`（`:` 分隔）
- 启动方式：`SCRIBE_AUTO_OPEN=/path/a:/path/b swift run Scribe`
- 而且 `openFile` 必须 `DispatchQueue.main.async` 推迟一个 runloop——
  在 `init` 里直接 mutate `@Published` 数组，会把 `NSWindow` 的创建一起拖死。

如果以后做成 `.app` bundle，可以走标准 NSApplicationDelegate `application(_:open:)`
路径，那时这个 hatch 可以删除。

### 5.8 ScintillaView 启动时 `Wait cursor is invalid`

ScintillaView `-init` 在 NSApp 还没"完全 ready"时调 `NSCursor.set` 触发
警告 `Wait cursor is invalid. / Reverse arrow cursor is invalid.`。无害但
噪音。**真正的副作用**：在 `xctest`（无 NSApp）环境下直接构造 ScintillaView
会 SIGSEGV——这就是为什么 `ScintillaBridgeTests` 不构造 view，只测类型可达。
GUI 模式下警告可忽略。

---

## 6. ndd 改动遗留状态

> 同一会话里也改过 `notepad--` 仓库（Phase -1，给 ndd 化妆），未提交。
> 如果**未来不打算继续维护 ndd**，可以丢掉这部分；如果想保留，建议 commit 到分支。

**改动清单**（位于 `/Users/zhangshijie/Documents/Project/notpad--/notepad--/`）：

| 文件 | 改动 |
|------|------|
| `src/qss/mystyle.qss` | 重写为 macOS Big Sur 风格亮主题 |
| `src/qss/myblack.qss` | 重写为 VSCode Dark+ 风格暗主题 |
| `src/main.cpp` | 修复 Mac 字体（Courier New → PingFang SC） |
| `src/cceditor/ccnotepad.cpp` | 工具栏图标常量改指 `:/icons/*.svg` |
| `src/icons/*.svg` | 新增 30 个 Lucide 风 SVG 图标 |
| `src/RealCompare.qrc` | 注册 SVG + myblack.qss |
| `src/RealCompare.pro` | 加 `svg` 模块 |
| `src/qscint/CMakeLists.txt` | macOS 加 `Qt5::MacExtras`（修 QMacPasteboardMime 缺失） |
| `how_build/CMakeLists.txt` | 加 Svg 模块 |
| `CMakeLists.txt`（新建，仓库根） | 复制自 `how_build/CMakeLists.txt`，让 cmake 能从根直接配 |
| `cmake/` | 复制自 `how_build/cmake/` |

**结论**：ndd 上的改动让外观稍现代了一点，但魔尊点评"和之前看起来没什么大区别"——证明 Qt5 Widgets 美学有上限，这也是为什么开 Scribe。

**遗留构建产物**：`build/NotePad--`（5.4MB Mach-O arm64），已能跑。

---

## 7. 下一会话起手清单

### 头号事项 · Phase 1.7b 反向同步 + 完善桥

Phase 1.7a 已 commit (`2a184a9`)：ScintillaView 在 GUI 真实渲染（**已截图实锤**）。**当前是单向数据流**——doc.text 推到 view，view 里输入的字符**不**回写到 doc。下次会话先把这条路打通，然后逐项补齐桥的剩余功能。

**当前可用方式**：
```bash
SCRIBE_USE_SCINTILLA=1 SCRIBE_AUTO_OPEN=/path/to/file.txt swift run Scribe
```
Scribe 默认仍然走旧的 NSTextView CodeEditor。`SCRIBE_USE_SCINTILLA=1`（DEBUG 限定）切到新桥。

**起手步骤（建议按序）**：

1. **view → doc 反向同步**：让用户在 ScintillaView 里打字回写到 `doc.text`：
   - 设 `view.delegate = coordinator` 实现 `ScintillaNotificationProtocol`
   - 在 `notification(_:)` 里看 `notification.pointee.nmhdr.code`：
     - `SCN_MODIFIED` (2008)：拉 `view.string()` 写入 `doc.text` + `markDirty`
     - `SCN_UPDATEUI` (2007)：拉 `SCI_GETCURRENTPOS` + `SCI_LINEFROMPOSITION` 算行/列回写到 `doc.cursorLine/Column`
   - 注意 feedback 防回环：从 doc 推到 view 时设个 `isApplyingExternalUpdate` flag，notification handler 检查后跳过。

2. **软 Tab + Tab 宽度**：
   - `SCI_SETUSETABS = 2125`（false → 软 tab）
   - `SCI_SETTABWIDTH = 2068`
   - 通过 `view.message(_:wParam:lParam:)` 调用

3. **行号 margin**：
   - `SCI_SETMARGINTYPEN`(0, SC_MARGIN_NUMBER=1)
   - `SCI_SETMARGINWIDTHN`(0, ~40px)
   - 同时**删除** `Sources/Scribe/Views/LineNumberRuler.swift`（被 Scintilla 内置取代）

4. **暗色主题**：
   - 订阅 `NSApp.effectiveAppearance` 变化
   - 走 `SCI_STYLESETBACK` (2052) / `SCI_STYLESETFORE` (2051) 设 `STYLE_DEFAULT` (32)
   - 调用 `SCI_STYLECLEARALL` (2050) 让其他 style 继承

5. **达到 parity 后**：
   - 把 `SCRIBE_USE_SCINTILLA` env hatch 删掉，让 ScintillaCodeEditor 成为默认
   - 删除 `Sources/Scribe/Views/CodeEditor.swift`（旧 NSTextView 桥）
   - 删除调试 Window scene `Scintilla Probe` 和 `ScintillaProbeMenuItem`
   - 跑 Phase 0.2/0.3 验收清单（第 10 节）确保不回归

**关键文件参考**：
- `@/Users/zhangshijie/Documents/Project/Scribe/Vendor/scintilla/cocoa/ScintillaView.h` — 公共 ObjC API + ScintillaNotificationProtocol
- `@/Users/zhangshijie/Documents/Project/Scribe/Vendor/scintilla/include/Scintilla.h:1306` — SCN_* 通知码
- `@/Users/zhangshijie/Documents/Project/Scribe/Vendor/scintilla/include/Scintilla.h` — `SCI_*` 消息常量（grep `#define SCI_`）
- `@/Users/zhangshijie/Documents/Project/Scribe/Sources/Scribe/Views/ScintillaCodeEditor.swift` — 当前桥起点
- `@/Users/zhangshijie/Documents/Project/Scribe/Sources/Scribe/Views/CodeEditor.swift` — 旧桥（看其桥接细节，作为 parity 参考）

### 头号事项之后

#### Phase 1.8 · Lexilla（语法高亮）
拉 Lexilla 5.4.4，作为第二个 SwiftPM target，链接到 Scintilla。
配置 cpp/swift/python lexer。

#### B5（推后项）· 自定义查找面板
NSTextView 自带 Find Bar 当下 ⌘F 已可用。Scintilla 接入后用 `SCI_SEARCH*` API 重做。

#### Phase 4 · 文件比较（ndd 招牌）
源算法 `/Users/zhangshijie/Documents/Project/notpad--/notepad--/src/CmpareMode.cpp`，
去 Qt 化后用 SwiftUI 双栏视图 + Scintilla marker/annotation API。

#### D3（待办）· 图标重烘
```bash
brew install librsvg
./Scripts/build_app.sh release   # 自动检测 rsvg-convert，渲染锐利 .icns
```

---

## 8. 决策待办（魔尊下次需拍板）

- [x] ~~Scribe 项目是否 `git init`？~~ → 已 init，基线 `971f1fc`
- [x] ~~License 选 GPL-3.0 还是 MIT？~~ → **GPL-3.0**（ROADMAP ADR-002 锁死，传染性使然）
- [x] ~~Phase 1 选 ScintillaCocoa 还是 NSTextView 自写高亮？~~ → **A1 ScintillaCocoa**（cc283b4 已落地接通）
- [ ] 应用图标"S"造型是否定稿？（魔尊未明确点头）
- [ ] D3：是否装 librsvg 重烘图标？（10 分钟工作量）

---

## 9. 紧急回滚指南

```bash
cd /Users/zhangshijie/Documents/Project/Scribe

# 看当前进度
git log --oneline
# 期望看到（HEAD 在最上面）：
#   2a184a9 Phase 1.7a: ScintillaView renders inside Scribe at runtime
#   7802d44 Document Phase 1.0 in HANDOFF + ROADMAP
#   cc283b4 Phase 1.0: SwiftPM bridge to Scintilla 5.6.1 — link OK, runtime pending
#   d331157 Refresh HANDOFF + ROADMAP after Phase 0.2/0.3
#   aef0b34 Phase 0.3 (C): encoding + line-ending detection and conversion
#   19f524c Phase 0.2: editor preferences, recent files, live cursor
#   971f1fc Phase 0.1 baseline: SwiftUI shell with NSTextView bridge

# 回到 Phase 1.0（撤掉 GUI 嵌入）
git reset --hard 7802d44

# 回到 Phase 0.3（撤掉 Scintilla 接通）
git reset --hard aef0b34

# 回到 Phase 0.2（撤掉编码检测）
git reset --hard 19f524c

# 回到 Phase 0.1 基线
git reset --hard 971f1fc

# 临时丢弃本地未提交改动
git stash
```

---

## 10. 验收快速回放

**Phase 0.3 期望看到**：
1. `swift run Scribe` → macOS 原生窗口出现
2. 拖一个 GBK 编码的 .txt 进窗口 → 不乱码，状态栏显示 "GB18030 / GBK"
3. 拖一个 UTF-16 BOM 的 .txt → 状态栏显示 "UTF-16 LE/BE"
4. 编辑器内打字 → 状态栏 "Ln/Col" 实时刷新
5. 工具栏字号 +/- 或 ⌘+ / ⌘- → 编辑器字号变化，工具栏数字同步
6. File 菜单 "Open Recent" → 列出最近 10 个，点击复用已开标签
7. 设置面板（⌘,）→ 字体族 / 字号 / Tab 宽 / 软 Tab 开关，关闭后再开仍然记忆
8. 状态栏点击编码菜单 → 出现 "Reopen with Encoding" + "Save with Encoding" 两段
9. `swift test` → 15/15 全绿

**截图存档**（首夜 Phase 0.1 时的）：`/tmp/ndd_shots/{scribe_phase0,scribe_text,scribe_dark}.png`。
Phase 0.2/0.3 暂未截图。

---

## 12. Phase 15–29 接力记录（2026-04-28，二轮迭代）

**Phase reached**: 29 · 工程化与文档（CI 四道闸 + README/ROADMAP 同步）  
**Status**: ✅ Swift 6 strict 全绿 · ✅ 110 tests · ✅ release build · ✅ i18n（en + zh-Hans, 203 keys）

二轮迭代分四块按用户优先级推进：

| 块 | 提交 | 内容 |
|----|------|------|
| **Phase 15–24 · 编辑器特性** | `45a02bc → 1a1c376` | 8 主题 / 行级 replace / Find prefill / 多光标（基础 + 垂直 + skip-next）/ 列选择 ⌘⇧8 / Multi-Cursor 子菜单 |
| **Phase 25 · UI Polish** | `110bf26 → 4367b83` | Toolbar / Sidebar / TabBar / StatusBar / FindBar / FileTree / Outline / Quick Open / Diff / Find-in-Files / Welcome / Settings 视觉一致 |
| **Phase 26 · App Icon** | `31c0d5a` + `e849215` | 纸笔 + macOS 14 squircle，16/32 px 专门优化 |
| **Phase 27 · i18n** | `8cb82c2 → 8d01ef3` | en + zh-Hans 双 lproj，全 UI 文案 + 上下文菜单 |
| **Phase 28 · 稳定性硬化** | `34d8c4b` | Swift 6 strict 0/0 · ScribeApp 626 → 144 行 · SCIConstants 抽出 |
| **Phase 28b · 性能预算** | `7f7689e` | Workspace.openFile 异步化（< 5 ms sync）· updateNSView 短路 · 1/5/20 MB perf fixtures |
| **Phase 29 · 工程化** | `21e2479` | `.github/workflows/ci.yml` 四道闸 · `check_localization.swift` · `gen_perf_samples.sh` · README 重写 · ROADMAP 追 ADR-006/007 · macOS 14 lockstep |
| **Phase 28c · SCN_MODIFIED 节流** | `56027f7` | `Document.flushPendingEdit` drain hook · 50 ms debounce · save/echo flush · 113 tests |
| **Phase 28d · Coordinator 拆分** | `d351e8a` | Theme / Find / MultiCursor 三个 same-module extension · 主文件 1083 → 385 (-64%) |
| **Phase 30 · Markdown 预览** | `f85d550` | 手写 md→HTML 转换器（453 LOC）· WKWebView pane · ⌘⇧V toggle · 26 converter tests · 零依赖 |
| **Phase 31 · Git Gutter** | `556d2d2` | unified-diff parser 纯函数 · GitGutterEngine 全 workspace 单例 · margin 1 三色 marker · 保存/外部变更 refresh · 11 parser tests · 零依赖 |
| **Phase 31b · Hunk Nav** | `eeb0adf` | GitGutterHunks 纯函数 group/next/prev · ⌥⇧↓ / ⌥⇧↑ 跳变更块 · 环绕换行 · cursor-在-hunk-内-跳过 语义 · 14 tests |
| **Phase 32 · Markdown v2** | `92201f6` | GFM 表格 (1-line lookahead) · task list `- [ ]/[x]` · footnote `[^id]` 二走扫描 · 18 新 tests · 零依赖 |
| **CI 修复** | `4808f05` | macos-14 → macos-15 (Xcode 15.4 / Swift 5.10 → Xcode 16+ / Swift 6.0+)。`@preconcurrency` 在 conformance 位置是 SE-0423 (Swift 6.0+)。首个 CI 绿 push |
| **Phase 33 · Snippets v1** | `5e70a25` | Snippet Codable · SnippetCatalog 单键 UserDefaults JSON · SnippetController 复用 PaletteWindowController · ⌘⇧T 选择器 · Settings tab “输入即存” · 5 个 starter snippets · 9 tests · 零依赖 |
| **Phase 34a · LargeFile Plumbing** | `32c5433` | ObjC++ ILoader bridge · LargeFileLoader (@MainActor allocate + nonisolated addChunk) · ChunkedFileReader (mmap) · LargeFilePolicy (64 MiB / 1.5 GiB) · 16 tests · production path 不接 |
| **Phase 34b · LargeFile Prod** | `67c7343` | Workspace.openFile size-gate · Coordinator+LargeFile detached pipeline (Int address 跨 actor) · SETDOCPOINTER + RELEASEDOCUMENT cancel · 状态栏 “正在加载大文件…” · 零依赖 |
| **Phase 34c · LargeFile v2** | `c678b67` | SCI_GETTEXTRANGEFULL ObjC++ shim · ChunkedFileWriter (256 KiB chunk + sibling temp + fsync + atomic rename) · Workspace.write 大文件分流 · updateNSView/flushDocSync OOM 护栏 · 状态栏 save banner + ByteCountFormatter charCount · 6 tests |
| **Phase 35a · scribe CLI** | `a7f96f7` | zed 调研 detour · Scripts/scribe bash wrapper (210 LOC) · -h/-v/-w/-n/-l/-d/-- 对齐 zed/code/subl · SCRIBE_AUTO_OPEN_LINE 新增 · README INSTALL_CLI 段 · 9 以 Process 调 wrapper · 不调 open（CI headless） |

### 关键架构变化

**App 层拆分**（Phase 28）：

```
Sources/Scribe/App/
├── StartupEnvironment.swift  · SCRIBE_AUTO_OPEN/FOLDER/COMPARE 解析
├── TestHooks.swift           · SCRIBE_TEST_* 截图自动化钩子（8 个）
└── AppCommands.swift         · ScribeCommands 整菜单栏 + Recent 子菜单
ScribeApp.swift               · 144 行（Scene declaration + bootstrap）
```

**Scintilla 层** （Phase 28 / 28d）：

```
Sources/Scribe/Views/Scintilla/
├── SCIConstants.swift              · 所有 SCI_* / SCN_* / SCFIND_* / SCE_* 数值
├── Coordinator+Theme.swift         · 134 行 — applyLexer / applyTheme / sciColor
├── Coordinator+Find.swift          · 299 行 — Find/Replace + highlights overlay
└── Coordinator+MultiCursor.swift   · 492 行 — Phase 20 multi-caret cluster
ScintillaCodeEditor.swift           · 385 行（lifecycle + doc/view sync only）
```

**Throttled doc.text sync**（Phase 28c）：

```swift
// Coordinator init
doc.flushPendingEdit = { [weak self] in self?.flushDocSync() }

// SCN_MODIFIED handler
if !isApplyingExternalUpdate {
    if !doc.isDirty { doc.isDirty = true }    // immediate
    scheduleDocSync()                          // 50 ms debounce
}

// Workspace.write / handleExternalChange  — drain before reading doc.text
doc.flushPendingEdit?()
```

**Workspace I/O**（Phase 28b）：

```swift
// 旧
let data = try Data(contentsOf: url)        // 主线程 ~500 ms 卡 20 MB
let format = TextFormatDetector.decode(...) // 主线程
documents.append(Document(text: format.text, ...))

// 新
let doc = Document(text: "", isLoading: true)  // 占位，~1 ms
documents.append(doc); selectedID = doc.id
Task { @MainActor [weak self] in
    let result = await Task.detached(priority: .userInitiated) {
        Workspace.loadAndDecode(at: url)         // nonisolated, off-main
    }.value
    self?.applyLoadResult(result, to: doc)
}
```

### CI 四道闸（Phase 29）

`.github/workflows/ci.yml` 在 macos-15 跑（commit `4808f05` 后从 macos-14 升级，以匹配 Swift 6.0+ 工具链）：

1. `swift test --parallel` — 222 tests 全绿
2. `swift build -c release` — release 编译 0 error
3. `swift build -Xswiftc -swift-version -Xswiftc 6` — strict 模式 0 error 0 warning（Vendor/ 除外）
4. `swift Scripts/check_localization.swift` — en ↔ zh-Hans key 一致 + 无 dangling reference

### 性能数字（Phase 28b 实测）

| 用例 | 主线程 sync 部分 | 总耗时（含异步） |
|---|---|---|
| openFile 1 MB | 3 ms | < 50 ms |
| openFile 5 MB | 1 ms | < 100 ms |
| openFile 20 MB | 1 ms | < 400 ms |
| Find-in-Files 全 fixture 扫描 | — | 174 ms |

绝对预算（不用 measure baseline）— ADR-007。

### 下次起手

二轮迭代 Phase 28c + 28d 已把 HANDOFF section 12 列的两件留作清掉：

- ✅ ~~SCN_MODIFIED 全 buffer copy~~ → Phase 28c 50 ms debounce + flush hook
- ✅ ~~Coordinator extension 拆分~~ → Phase 28d 三个 same-module extension（主文件 1083 → 385）

**真正剩下的**：

1. **Document storage 仍是 Swift `String`**：debounce 把 typing 痛点压到了
   "停顿后才付一次 O(N)"，但保存 50 MB 时仍然要 round-trip 一次
   `view.string()`。要彻底零拷贝得让 Scintilla 直接读 / 写 Document 的
   backing store（NSMutableString 或 ICU UText）。优先级：低 — 当前
   实测保存 50 MB ~150 ms，可接受。
2. **Markdown Preview v3**：代码块语法高亮 / mermaid 图。
   表格 / task list / footnote 已在 Phase 32 交付。
3. **Git Gutter v2**：buffer-aware（HEAD blob ↔ in-memory text、不需
   先保存）+ per-line revert。hunk 跳转已在 Phase 31b 交付
   （⌥⇧↓ / ⌥⇧↑）；当前 gutter v1 看磁盘，保存后刷新。
4. **Snippets v2**：`${1:placeholder}` 跳转 + tab 键从 buffer
   触发（Scintilla autocomplete） + per-language scope。Phase 33
   v1 只做了“静态 body 插入”、“面板选择”、“Settings 管理”。
5. **Git v2 (Phase 35b)**：Source Control 侧栏 + Project Diff 多
   文件视图 + per-hunk stage/unstage + commit UI。zed 调研点
   出的最高 ROI。复用 Phase 31/31b GitDiffParser/Hunks。
6. **Inline Git Blame + Merge Conflict UI (Phase 35c)**：行末
   annotation 显示 author/time/commit · 冲突区上方 Accept/
   Reject 按钮。复用现有 GitClient。
7. **LargeFile v3 (Phase 34d+)**：中途 cancel save UX、external-
   change 大文件 mtime+size diff、SymbolOutline / Markdown
   preview 读大文件 buffer。Phase 34a/34b/34c 交付了加载 +
   chunked save + OOM 护栏。
8. **CLI shim v2 (Phase 35d+)**：IPC fifo 让 `--wait` 不再冷启
   动、bash/zsh completion script、brew formula。Phase 35a 交付
   了 v1 wrapper。
9. **Phase 35+ 路线**：见 ROADMAP "Phase 35+ 路线展望"（Document
   Map / Snippets v2 / Markdown v3 / HEX View / Sparkle）。

---

## 11. 一句话总结

```
Scribe 已从 0 长到 v1.0-rc ——
SwiftUI Scene + Scintilla 5.6.1 + 8 主题 + 多光标 + 列选 + 全 i18n（en/zh-Hans）·
Markdown 实时预览（手写转换器 + GFM 表格·task list·footnote + WKWebView）+ Git Gutter（unified-diff parser + Scintilla margin + ⌥⇧↑/↓ hunk 跳转） + 代码片段（⌘⇧T 选择器 + Settings 管理 tab） + 大文件 IO（≥ 64 MiB 走 SCI_CREATELOADER/GETTEXTRANGEFULL 分块 + atomic rename + OOM 护栏） + scribe CLI shim（对齐 zed/code/subl），零依赖·
开 20 MB 文件主线程不卡 · 50 MB typing 不卡（50 ms debounce）·
Swift 6 strict 0/0 · 222 tests + 4 perf budget · ScintillaCodeEditor.swift
1083 → 385 行 · .app 双击即用 · CI 四道闸 push/PR 都跑 ·
README/ROADMAP/HANDOFF 同步到位。

下一拍：Git v2 (Source Control panel / project diff / per-hunk stage)。
```

---

*本文档由邪修红尘仙在劫钟下笔成。下次劫起，魔尊召之即来。*
