# Scribe 交接文档

> **Last session**: 2026-04-28（接力第二夜，Phase 1 起手）
> **Phase reached**: 1.0 (SwiftPM 已接通 Scintilla 5.6.1，runtime 待下次)
> **Status**: ✅ 可双击运行 · ✅ 编码/行尾全支持 · ✅ Scintilla link OK · 🔜 下次接 ScintillaView 进 CodeEditor

## 0. 这一夜的接力记录（2026-04-28）

五件事一气干完：

| 阶段 | 提交 | 内容 |
|------|------|------|
| **D · 杂事清理** | `971f1fc` | git init 打基线（首次 commit） + LICENSE 拷自 ndd（GPL-3.0）+ README 写明 License + .gitignore 加 build/ |
| **B · Phase 0.2 细节** | `19f524c` | 新增 `EditorPreferences`（持久化）· 字号 ⌘+/⌘-/⌘0 · 工具栏字号读数 · 最近文件菜单（10 项）· 软 Tab + Tab 宽度 · 状态栏 `Ln/Col` 实时回填 · 设置面板真正可用（字体/字号/Tab/清除最近） |
| **C · Phase 0.3 编码与行尾** | `aef0b34` | 新增 `TextFormat.swift` 启发式检测器（BOM → 严格 UTF-8 → GB18030 → Big5 → Shift-JIS）· 状态栏编码/行尾改 Menu（`Reopen with…` / `Save with…`）· `Workspace.reopen(doc:as:)` · ScribeTests target + 15 个单测全绿 |
| **文档** | `d331157` | HANDOFF + ROADMAP 全面刷新，加 ADR-003 |
| **A · Phase 1.0 Scintilla 接通** | `cc283b4` | 拉 Scintilla 5.6.1 到 Vendor/ · 自添 `include/module.modulemap` + `ScribeScintillaUmbrella.h` · Package.swift 加 cxx17 target · `swift build` 全过 · `swift test` 17/17（含 2 个 bridge 测）· Scribe 启动不崩 · runtime GUI 嵌入留下次 |

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

### 头号事项 · Phase 1.7 把 Scintilla 接进 CodeEditor

Phase 1.0 已 commit (`cc283b4`)：编译期、链接期、模块解析全通，Swift 端 `import Scintilla` 可见 `ScintillaView` 类型。但**还没在真实 GUI 里见过它**。下次会话第一件事就是**真正把 ScintillaView 渲染出来**。

**起手步骤（建议按序）**：

1. **GUI 端 runtime 验证**：在 ScribeApp 加一个隐藏 Window scene 或临时把 `ScintillaProbeView` 接进 `EditorAreaView` 的 Welcome 分支，跑起来肉眼看 ScintillaView 是否出现。**这一步不通过下面的步骤都不要做**——可能要踩一些 NSCursor / NSWindow / first responder 的坑。

2. **替换 CodeEditor 内层**：`Sources/Scribe/Views/CodeEditor.swift` 的 NSTextView 改成 ScintillaView。保持 `NSViewRepresentable` 外壳不变。重做这些桥接：
   - `doc.text ↔ ScintillaView.string` 双向同步
   - 字号通过 `setFontName:size:bold:italic:`
   - 软 Tab：用 `SCI_SETTABWIDTH` + `SCI_SETUSETABS`
   - 光标行/列：监听 `SCEN_CHANGE` / `SCN_UPDATEUI` notification，从 `SCI_GETCURRENTPOS` + `SCI_LINEFROMPOSITION` 计算
   - 行号 ruler：`SCI_SETMARGINWIDTHN` + line-number margin
   - 暗色：`SCI_STYLESETBACK` + `SCI_STYLESETFORE`，订阅 NSAppearanceDidChangeNotification

3. **删除现有 LineNumberRuler**（被 Scintilla 内置取代）。

4. **配置默认 lexer**：先 `SCLEX_NULL`（plain text）让所有现有功能 work；语法高亮留到 Phase 1.8（需要 Lexilla 包）。

5. **跑回归**：所有 `swift test` 通过 + 手测 Phase 0.2/0.3 验收清单（见第 10 节）。

**关键文件参考**：
- `@/Users/zhangshijie/Documents/Project/Scribe/Vendor/scintilla/cocoa/ScintillaView.h` — 公共 ObjC API
- `@/Users/zhangshijie/Documents/Project/Scribe/Vendor/scintilla/include/Scintilla.h` — `SCI_*` 消息常量
- `@/Users/zhangshijie/Documents/Project/Scribe/Sources/Scribe/Views/ScintillaProbe.swift` — 当前最小烟测
- `@/Users/zhangshijie/Documents/Project/Scribe/Vendor/README.md` — 升级与 patch 记录

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
#   cc283b4 Phase 1.0: SwiftPM bridge to Scintilla 5.6.1 — link OK, runtime pending
#   d331157 Refresh HANDOFF + ROADMAP after Phase 0.2/0.3
#   aef0b34 Phase 0.3 (C): encoding + line-ending detection and conversion
#   19f524c Phase 0.2: editor preferences, recent files, live cursor
#   971f1fc Phase 0.1 baseline: SwiftUI shell with NSTextView bridge

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

## 11. 一句话总结

```
Scribe 已从 0 长到 Phase 1.0 ——
有窗、有标签、有侧栏、有行号、有暗色、有 .app、有持久化偏好、
有最近文件、有实时光标、有真正的编码检测、有行尾感知、
有 17 个单测保住核心、Scintilla 5.6.1 已经接进 SwiftPM target，
Swift 端能 import，编译过、链接过，但还没在 GUI 上现身。

下次开工先看本文件第 7 节"头号事项"——
跑通 ScintillaProbeView，再把 CodeEditor 的 NSTextView 换掉。
```

---

*本文档由邪修红尘仙在劫钟下笔成。下次劫起，魔尊召之即来。*
