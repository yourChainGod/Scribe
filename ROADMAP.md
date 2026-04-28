# Scribe Roadmap

> **路线对标**（2026-04-28 重排）：参考 [`notepad-plus-plus-mac`](https://github.com/notepad-plus-plus-mac/notepad-plus-plus-macos)
> 的功能拓扑后调整。Scribe **不**追求 NPP 100% feature parity，但借鉴其面板架构 /
> 命令调色板 / Document Map 等已被验证的 macOS 编辑器特性。详见底部 ADR-004/005。

## Phase 0 · UI 骨架 ✅

**目标**：能跑的最小 SwiftUI macOS 应用，让我们看到美学起点。

- [x] 项目立项：目录结构、README、ROADMAP
- [x] Swift Package + SwiftUI `@main` 入口
- [x] 主窗口骨架：侧栏 / 标签 / 编辑区 / 状态栏
- [x] 编辑区 NSTextView 桥（行号 ruler、等宽字体、暗色跟随）
- [x] `swift run` 能启动并显示主窗口
- [x] 多标签、文件 IO、拖放、`.app` 打包

## Phase 0.2 · 偏好与产品手感 ✅ (commit `19f524c`)

- [x] `EditorPreferences` 持久化（字号 / 字体族 / Tab 宽 / 软 Tab / 最近文件）
- [x] 字号 ⌘+ / ⌘- / ⌘0，工具栏字号读数
- [x] File → Open Recent 菜单（10 项 + Clear）
- [x] 状态栏 `Ln/Col` 实时回填
- [x] 设置面板真正可用（字体族 / 字号 / Tab / 清除最近）

## Phase 0.3 · 编码与行尾 ✅ (commit `aef0b34`)

- [x] 启发式编码检测（BOM → 严格 UTF-8 → GB18030 → Big5 → Shift-JIS）
- [x] 行尾自动检测 + 归一/还原（grapheme 陷阱已避开）
- [x] 状态栏编码 / 行尾 Menu（Reopen with… / Save with…）
- [x] `Workspace.reopen(doc:as:)` 含脏文档确认
- [x] ScribeTests target，15 单测全绿

## Phase 1 · 编辑器内核（进行中，ADR-003 已选 ScintillaCocoa）

**目标**：替换占位 NSTextView 为生产级编辑器（Scintilla）。

- [x] **1.0** SwiftPM 接通 Scintilla 5.6.1（commit `cc283b4`）
  - Vendor/scintilla 拉取 + 添 module.modulemap + umbrella header
  - Swift `import Scintilla` 编译 / 链接 / 模块解析全通
  - 17/17 测试 + Scribe 启动不崩
- [x] **1.7a** ScintillaView 在 GUI 真实渲染（commit `2a184a9`）
  - 新增 `ScintillaCodeEditor` SwiftUI 桥（doc → view 单向）
  - `SCRIBE_USE_SCINTILLA=1` env hatch 切换新旧桥
  - `SCRIBE_AUTO_OPEN` env var 绕过 SwiftUI WindowGroup 不接 argv 的坑（HANDOFF 5.7）
  - 截图实锤：Swift + 中日韩注释正常上屏
- [ ] **1.7b** view → doc 反向同步 + 软 Tab + 行号 margin + 暗色（HANDOFF 第 7 节 5 步）
- [ ] **1.7c** 删 env hatch + 旧 CodeEditor + 调试探针窗口

**验收**：当前可用：`SCRIBE_USE_SCINTILLA=1 SCRIBE_AUTO_OPEN=… swift run Scribe`
完成 1.7b/c 后：默认即 Scintilla，原 NSTextView 桥退役。

## Phase 1.8 · Lexilla + 主题管理 (1-2 会话)

**目标**：让 Scintilla 上屏的代码有颜色。学 npp-mac 的 `NppThemeManager.mm`
集中管理。

- [ ] 拉 Lexilla 5.4.4 到 `Vendor/lexilla`，仿照 Scintilla 配 SwiftPM target
- [ ] 新建 `Sources/Scribe/Models/ThemeManager.swift` 集中管理：
  - 文档颜色族（背景 / 前景 / 选区 / 行号 margin / caret）
  - 8 个内置 SCE_* style 配色（关键字 / 字符串 / 注释 / 数字 / preprocessor / type / function / string）
  - 暗色 / 亮色双套，跟随 NSAppearance 切换
- [ ] 默认 8 种 lexer：cpp / swift / python / json / md / sh / xml / html / js / ts
- [ ] 文件扩展名 → lexer 映射表
- [ ] 状态栏点击语言名可手动切换

**验收**：打开 ndd 的 9985 行 `ccnotepad.cpp`，关键字 / 字符串 / 注释三色全开，
丝滑滚动。

## Phase 2 · 文件 / 编码 (大部分提前完成 ✅)

**目标**：能用作日常编辑器。

- [x] 文件打开 / 保存（NSOpenPanel / 拖放）— Phase 0.1
- [x] 多标签管理（Workspace + Document）— Phase 0.1
- [x] 编码检测：自实现 BOM + 启发式（参考 ndd `Encode.cpp` 但 Swift 重写）— Phase 0.3
- [x] 编码转换：UTF-8/16 LE/BE、GB18030、Big5、Shift-JIS、EUC-KR、ASCII — Phase 0.3
- [x] 行尾符识别 / 转换：CRLF / LF / CR — Phase 0.3
- [ ] 文件变动监控（FSEvents）— 提示外部修改 + 询问 reload
- [ ] Recent Folders（File → Open Recent Folder）

## Phase 3 · 命令调色板 ⌘⇧P (1 会话)

**学 npp-mac 的 `CommandPalettePanel.mm`**。VSCode 风格。这是现代编辑器的
门面特性，工程量小但用户感知强。

- [ ] `Sources/Scribe/Views/CommandPalette.swift`：浮窗 + 模糊搜索
- [ ] `Sources/Scribe/Models/CommandRegistry.swift`：Action 注册中心
  - 内置 ~30 条命令：所有菜单项 + Switch Tab + Reopen with Encoding 等
  - 支持权重排序（最近用过的排前）
- [ ] 调用走 SwiftUI Command + NSPanel 浮窗（关键路径必要时下沉到 AppKit）
- [ ] 模糊匹配：Sublime 风算法（每个字符必须按序出现）

**验收**：⌘⇧P 弹窗 → 输 "enc" → "Reopen with Encoding…" 排第一 → Enter 触发。

## Phase 4 · 查找替换体系 (2 会话)

**学 npp-mac 的 `FindReplacePanel.mm` + `FindInFilesPanel.mm` +
`SearchResultsPanel.mm` + `IncrementalSearchBar.mm`**。

- [ ] **⌘F · 当前文件**：sheet 风格 + Scintilla 内置 `SCI_SEARCH*`
  - 区分大小写 / 全词 / 正则 / 高亮所有匹配
- [ ] **⌘⇧F · 跨文件**：独立 NSPanel 浮窗
  - 范围：当前文件夹 / 当前 workspace / 自定义路径
  - 结果挂在新的 `SearchResultsPanel`（侧栏底部抽屉）
- [ ] **⌘R · 增量搜索栏**：编辑器顶部细窄 bar
  - 类 Vim `/` 风格，每输一个字符立即跳转
- [ ] 替换：sheet → NSAlert 确认 → SCI_REPLACETARGETRE 走

**验收**：跨文件查找 "openFile" 能在 Scribe 自身代码库找出 5+ 命中，点击跳转。

## Phase 5 · 招牌特性 · 文件比较 (2-3 会话)

ndd 的看家本领，但用 Scintilla marker / annotation 重做（不直接移植 Qt diff）。

- [ ] 算法层：`Sources/Scribe/Models/Differ.swift`
  - 借鉴 ndd `CmpareMode.cpp` 的 Myers diff 思路，Swift 重写
  - 输入两个 String，输出 `[(LineOp, lineNumber)]`（add / del / change / equal）
- [ ] UI 层：`Sources/Scribe/Views/DiffView.swift`
  - 双 ScintillaCodeEditor 横排
  - 用 `SCI_MARKERADD` 加变更标记到行号 margin
  - 用 `SCI_ANNOTATIONSETTEXT` 显示对侧多出的内容
  - 同步滚动（监听 `SCN_UPDATEUI` + 手动同步另一侧）
- [ ] 跳转：⌘↓ 下一处差异，⌘↑ 上一处
- [ ] 触发：File → Compare with… (⌥⌘D) / 拖两个文件到 Dock 图标

**验收**：拖两个版本的 `ccnotepad.cpp` 进 Scribe → 双栏对照 + 行级红绿高亮 +
margin 标记 + ⌘↓ 跳到下处差异。

## Phase 6 · Document Map（小地图） (0.5 会话)

**学 npp-mac 的 `DocumentMapPanel.mm`**。Scintilla 提供原生支持
（`SCI_LINESONSCREEN` + 缩放渲染）。

- [ ] 编辑器右侧细条 minimap，等高占位
- [ ] 鼠标点击 / 拖动跳转
- [ ] 当前可见区域反白
- [ ] 设置开关（默认开）

**验收**：打开 9985 行文件 → 右侧出现 minimap → 点击底部跳到末尾。

## Phase 7 · Function List / 大纲面板 (1 会话)

**学 npp-mac 的 `FunctionListPanel.mm`**，但更克制。

- [ ] 侧栏新分区 "OUTLINE"
- [ ] 简化版规则：cpp/swift/py 用语言无关正则提取（func/class/struct）
- [ ] 点击跳转 + 当前光标行所在函数高亮
- [ ] **不做** UDL 风格的可配置规则——太重

**验收**：打开 `Workspace.swift` → OUTLINE 列出所有 `func`/`var`/`init`，
点击 `openFile` → 编辑器跳到该行。

## Phase 8 · Git gutter + SCM 面板 (2 会话)

**学 npp-mac 的 `GitPanel.mm + GitHelper.mm`**，但**不**做 commit/push UI（
那是 GitHub Desktop / Tower 的领地）。

- [ ] **Git gutter**：编辑器行号 margin 旁边显示行级 +/- 改动标记
  - 用 Scintilla `SCI_MARKERDEFINE` + 自定义 marker
  - 检测：`git diff HEAD --no-color -U0` 解析输出
- [ ] **SCM 面板**：侧栏新分区 "SOURCE CONTROL"
  - 列出当前 workspace 的 dirty 文件
  - 点击 dirty 文件 → 打开 + 跳到第一处变更
- [ ] **Blame 提示**：选中行 → 状态栏显示 `git blame -L start,end`

**验收**：在 Scribe 自身仓库打开 `Workspace.swift`，做几行修改 → 行号边出现绿色
+ 标记 + 红色 - 标记。SCM 面板列出文件。

## Phase 9 · 主题系统 + 色板 (1-2 会话)

**学 npp-mac 的 `StyleConfiguratorWindowController.mm`**，但走 SwiftUI
Settings 风格（不开独立窗）。

- [ ] 扩展 `ThemeManager`（Phase 1.8 建的）
- [ ] 内置 5-8 个主题：One Dark Pro / Solarized Dark+Light / Dracula / Nord /
  Tomorrow / GitHub Dark+Light
- [ ] 设置面板新 tab "Theme"：
  - 主题选择器（缩略图预览）
  - 高级折叠：每个 SCE_* style 的颜色 / bold / italic 可改
- [ ] 持久化到 prefs，与 NSAppearance 暗色切换协同

**验收**：⌘, → Theme tab → 切到 Dracula → 编辑器即时变色 + 重启后保留。

## Phase 10 · i18n（中 / 英） (0.5 会话)

**学 npp-mac 的 `NppLocalizer.mm`**，但只做两种语言。

- [ ] 全部 UI 文案抽到 `Localizable.strings`
- [ ] 中文翻译（魔尊本人审）
- [ ] 设置面板 Language 选择（System / English / 简体中文）
- [ ] 跟随 macOS 系统语言 by default

**验收**：把 macOS 系统语言改简中 → Scribe UI 中文化。

## Phase 11 · 发布工程 (1-2 会话)

**学 npp-mac 已经做完的发布流水线**——他们已签名 + 公证 + DMG + 5 个 Releases。

- [ ] Universal Binary：`lipo -create arm64 + x86_64`
- [ ] 需要 Apple Developer ID（魔尊申请）
- [ ] 代码签名：`codesign --deep --sign "Developer ID Application: ..."`
- [ ] 公证：`xcrun notarytool submit ... --wait`
- [ ] DMG 制作：`create-dmg` 工具
- [ ] Sparkle 自动更新框架接入
- [ ] GitHub Releases 自动化（GitHub Actions）

**验收**：在干净 Mac 上下载 .dmg → 拖入 Applications → 双击启动无 Gatekeeper
警告。

## Phase 12 · 远期保留项

只读 HEX 视图（参考 ndd，但只做查看不做编辑）、二进制 diff、列编辑器、
剪贴板历史。优先级低于 11 之前的所有事。

---

## 不做项（明确划线）

| 不做 | 原因 |
|------|------|
| **插件系统** | ADR-004 永久搁置 |
| **UDL（用户定义语言）** | 几千行 dialog + parser，单人维护成本不划算 |
| **Macro 录制** | 现代用户用 Hammerspoon / Keyboard Maestro 替代 |
| **跨平台**（Win/Linux） | ADR-001 已决定，npp 上游覆盖了 |
| **NPP 插件兼容** | 与 npp-mac 路线分化 |

---

## 风险登记

| 风险 | 影响 | 缓解 |
|------|------|------|
| ~~ScintillaCocoa 集成复杂度~~ | ~~Phase 1 阻塞~~ | ✅ Phase 1.0/1.7a 已落地 |
| ~~Swift ↔ C++ interop~~ | ~~桥接层复杂~~ | ✅ 走 ObjC++ shim 解决（modulemap） |
| ndd diff 算法 Swift 重写工程量 | Phase 5 拖期 | 算法层先用 swift-collections + Myers，UI 层独立 |
| SwiftUI 浮动面板灵活度差 | Phase 3/4/9 阻塞 | 关键路径下沉到 NSPanel + NSViewRepresentable |
| 公证 / 签名需 Apple Developer ID | Phase 11 阻塞 | 魔尊申请（年费 $99） |
| Lexilla 升级与 Scintilla 解耦 | Phase 1.8 后续维护 | `Vendor/README.md` 已定升级流程 |

## 决策记录 (ADR)

### ADR-001 · 抛弃 Qt
**日期**：2026-04-27  
**决策**：完全脱离 Qt，使用 SwiftUI + AppKit。  
**原因**：Qt5 Widgets 美学上限低；Qt6 + QML 工程量同样巨大但跨平台收益已被 ndd 上游覆盖；走原生 Mac 可获最佳美学与性能。  
**代价**：失去跨平台能力，仅 macOS。

### ADR-002 · 保留 ndd C++ 算法核心
**日期**：2026-04-27  
**决策**：UI 全新，业务核心从 ndd 移植但去 Qt 化。  
**原因**：diff / 编码 / 大文件 / HEX 是 ndd 久经考验的算法资产，重写不划算。  
**代价**：每个模块需手工剥离 QString / QFile / QRegExp 等 Qt 依赖。  
**首次落地**：Phase 0.3 的 `TextFormat.swift` 借鉴 ndd `Encode.cpp` 的 BOM→UTF-8→GBK 判定顺序，Swift 重写而非 import。GPL-3.0 由此锁定。

### ADR-003 · 编辑器内核：Scintilla
**日期**：2026-04-28  
**状态**：✅ 决定——选 **A1 · ScintillaCocoa**，commit `cc283b4` 已落地最小骨架。  
**实际工程量**（vs 预估）：
- 接通 SwiftPM target：~1.5h（预估 6-10h，因 Scintilla 已自带 modulemap 减半）  
- 关键坑：原 modulemap 是 framework-style 不能用，且 ScintillaView.h `#import "Scintilla.h"` 是同目录引用——必须把新 modulemap 放到 `include/`（与 Scintilla.h 同目录）才能让 clang 模块构建期间 resolve 成功。`cSettings.headerSearchPath` 仅作用于 target 自身编译，不影响模块解析。  
- 落实剩余工作：~6-10h（GUI 嵌入 + CodeEditor 替换 + lexer 配置 + 暗色主题）

**结果**：
- Vendor 净增 ~2.3 MB / 135 文件（含 src/cocoa/include/bin/call/license/readme，跳过 doc/test/win32/gtk/qt/scripts 经 .gitignore）  
- Patch 仅两个新增文件（不动 Scintilla 上游源码），升级流程见 `Vendor/README.md`。

### ADR-004 · 不做插件系统
**日期**：2026-04-28  
**触发**：参考 [`notepad-plus-plus-mac`](https://github.com/notepad-plus-plus-mac/notepad-plus-plus-macos)
后做的取舍。  
**决策**：Scribe 永远**不**实现动态加载的插件机制。所有功能直接编进 Scribe
二进制，靠 git 仓库内的 feature 分支演进。  
**原因**：
1. 单人维护无法保证 plugin API 长期稳定（npp-mac 一个开发者要兜底 ~140 个插件兼容，是其永久背景成本）
2. macOS 沙盒 + 签名让第三方动态库加载成本巨高（每个插件本身还要单独签名）
3. 与 `notepad-plus-plus-macos` 路线刻意分化——他们是 NPP 上游的 Mac 端口，必须保留插件兼容；Scribe 是从头新做，应做出更克制的产品  
**代价**：放弃了 NPP 用户群里"Plugin Admin 装插件"的体验。但 Scribe 的目标
用户更接近 VSCode / Sublime / BBEdit 用户，这些产品都不靠插件兜底。  
**反向蕴含**：常用功能必须直接进二进制——Document Map、Function List、Git
gutter、Command Palette 都要做（见 Phase 6/7/8/3）。

### ADR-005 · 接受 SwiftUI 当前的代价
**日期**：2026-04-28  
**触发**：发现 npp-mac 用 ObjC++ + AppKit + NSWindowController 走"传统 macOS
应用"路线，且工程效率不低。同时 Scribe 在 Phase 1.7a 踩了几个 SwiftUI 的坑
（HANDOFF 5.7 / 5.8）。  
**决策**：继续 SwiftUI，**不**切回 AppKit/ObjC++。  
**对比**：
- npp-mac 走 ObjC++ + NSWindowController，与 NPP C++ 业务零成本互通
- Scribe 走 SwiftUI + Swift 业务，与 ScintillaView 通过 ObjC++ shim 桥接

**诚实承认 SwiftUI 当前坑**：
- `WindowGroup` 不接受 argv 文件参数（HANDOFF 5.7）
- 多窗口 / 浮动面板比 AppKit 笨拙（影响 Phase 3 命令调色板、Phase 4 查找窗口）
- 复杂列表 / 拖放时性能不如 NSTableView
- `@MainActor` 与 `NSViewRepresentable.Coordinator` 协议方法的边角问题（HANDOFF 5.5）

**应对策略**：
- **关键路径下沉**：复杂面板（命令调色板、跨文件查找窗口、主题编辑器）必要时直接用 `NSPanel` + `NSViewRepresentable`，不强求纯 SwiftUI
- **AppKit 桥接已有先例**：Phase 1.7a 的 `ScintillaCodeEditor` 就是这个模式，下沉是"已被验证的工程模式"，非例外
- **每个 Phase 跑通后留 hatch**：env var、`#if DEBUG` 分支临时保留，等下个 Phase 取代后再删

**受益**：
- SwiftUI 的现代美学是 Scribe 的核心差异化（与 npp-mac 直接区分）
- 与 npp-mac"传统 macOS 应用"形成定位互补——市场上同时存在两种风格
- 招募到的潜在贡献者更可能熟悉 Swift（ObjC++ 已是少数派语言）

**代价**：失去复用 ndd C++ 业务逻辑的廉价路径——Phase 5 文件比较算法只能 Swift
重写。但这本身已是 ADR-002 接受的代价。

---

## Phase 15 — 27 · 已完成（集中纪实）

ROADMAP 早期把 1.7b / 1.7c / 1.8 / 2-14 当成串行 phase 推进；实际开发节奏是
"按用户感知优先"重排过的。下面把 v1.0 之前的所有里程碑列出，按时间倒序：

- ✅ **Phase 27** · i18n 全覆盖（commit `8cb82c2` + `62ff434` + `8d01ef3`）
  - en + zh-Hans 双 lproj，203 keys，CI 校验
  - 上下文菜单、Sidebar / TabBar / FileTree / Editor 全部右键支持
  - Toolbar / FindBar / Find-in-Files / Settings / Welcome / Diff 全本地化
- ✅ **Phase 26** · App Icon（commit `31c0d5a` + `e849215`）
  - "纸笔 + macOS 14 squircle"主图；16/32 px 专门优化
- ✅ **Phase 25** · UI Polish（commit `110bf26` + `b076df3` + `6194c10` + `918ce67` + `4367b83`）
  - Toolbar / Sidebar / TabBar / StatusBar / FindBar 视觉一致
  - FileTree / Outline / Quick Open / Diff 内饰
  - Find-in-Files Sidebar、Welcome 最近文件、Settings 加 Appearance tab + 主题预览
- ✅ **Phase 24** · Multi-Cursor 子菜单（commit `1a1c376`）
- ✅ **Phase 23** · 列（矩形）选择 ⌘⇧8（commit `85596cd`）
- ✅ **Phase 22** · Skip Next Occurrence ⌃⌘D（commit `55823a5`）
- ✅ **Phase 21** · 垂直多光标 ⌥⌘↑/↓（commit `452be10`）
- ✅ **Phase 20** · 多光标基础（commit `7a05111`）
- ✅ **Phase 18** · Find 从 selection 预填（commit `f2b2c38`）
- ✅ **Phase 17** · 行级 Replace（commit `862364f`）
- ✅ **Phase 15** · 编辑器主题管理（commit `45a02bc`）— 8 套配色

## Phase 28 · 稳定性硬化（2026-04-28，commit `34d8c4b`）

**目标**：`swift build -Xswiftc -swift-version -Xswiftc 6` 全绿。

- [x] DirectoryWatcher: `nonisolated(unsafe)` FSEventStreamRef，修 deinit
- [x] FindInFilesEngine: enumerator `nextObject()` 替代 `for case as URL`（async 不可用）；
      `maxBytesPerFile` / `maxMatchesPerFile` 标 `nonisolated`
- [x] ThemeManager: `@MainActor var isDark` 修 NSApp 访问
- [x] DiffEditorPane: 去 `@preconcurrency`
- [x] FindInFilesSidebar: optionToggle 加 `@MainActor`

**架构修枝**：
- [x] ScribeApp.swift 626 → 144 行
- [x] App/StartupEnvironment.swift（SCRIBE_AUTO_*）
- [x] App/TestHooks.swift（SCRIBE_TEST_*）
- [x] App/AppCommands.swift（菜单栏整体）
- [x] Views/Scintilla/SCIConstants.swift（SCI_* / SCN_* 等数值常量）

## Phase 28b · 性能预算（2026-04-28，commit `7f7689e`）

**目标**：20 MB 文件打开不卡 UI；keystroke 不再因主线程对账阻塞。

- [x] **Workspace.openFile 异步化**：占位 Document → `Task.detached(.userInitiated)`
      读 + 解码 → MainActor 回填。Sync portion < 5 ms 恒定。
- [x] **updateNSView 短路**：`SCI_GETLENGTH` (O(1)) cheap signature 先比，length
      相同才付 `view.string()` 的 O(N) 全字符串 round-trip 代价。
- [x] **Performance 测试 + Fixture**：1 / 5 / 20 MB lorem-ipsum，绝对 wall-clock
      预算（不用 XCTest measure，避免每机器 baseline 噪音）。

**未完成**：见 Phase 28c。

## Phase 28c · SCN_MODIFIED 节流（2026-04-28，commit `56027f7`）

**目标**：50 MB 文件 typing 不卡 — 移除每按键 O(N) view → doc round-trip。

**改动**：
- `Document.flushPendingEdit: (() -> Void)?` — `@MainActor` 闭包，编辑器
  Coordinator 在 init 时安装、deinit 留给下一个 Coordinator 覆盖（Swift 6
  strict deinit 不能 mutate main-actor prop）。
- `Coordinator.scheduleDocSync()` — 每次 SCN_MODIFIED 取消上一个 Task，
  起新 50 ms timer；只有 typing 停顿后才付 O(N) `view.string()`。
- `Coordinator.flushDocSync()` — 立即 drain。`Workspace.write` 与
  `handleExternalChange` 在读 `doc.text` 前调 `doc.flushPendingEdit?()`。
- `applyText`（push path）取消 pending pull — 防 stale tick clobber。
- `doc.isDirty = true` 仍立即触发：title bar dot / 关闭确认 UI 不延迟。

**测试**：`Tests/ScribeTests/DocumentFlushTests.swift` 三例 — nil-by-default、
fire-and-mutate、replacement-survives-doc-swap。

**为什么 50 ms**：低于 user keystroke perception 阈值（~80 ms），覆盖
sustained typing burst，可调 `Coordinator.docSyncThrottleNanos`。

## Phase 28d · 跨 file extension 拆分（2026-04-28，commit `d351e8a`）

**目标**：`ScintillaCodeEditor.swift` 1083 行 → 主文件聚焦 lifecycle + sync。

**改动**：
- `Sources/Scribe/Views/Scintilla/Coordinator+Theme.swift`（134 行）
  — `applyLexer` / `applyTheme` / `applyLanguageStyles` / `setStyleColor` / `sciColor`
- `Sources/Scribe/Views/Scintilla/Coordinator+Find.swift`（299 行）
  — Find/Replace + highlights overlay
- `Sources/Scribe/Views/Scintilla/Coordinator+MultiCursor.swift`（492 行）
  — Phase 20 全 multi-caret cluster

**可见性契约**：仅 `currentLexer` / `lastHighlighted{Query,Flags,DocLength}`
四个 stored property 由 `private` 升 module-internal（同 module extension
所需）；其余 stored state 维持 `private`。helper functions 用 `fileprivate`
关掉外部调用面。

**结果**：主文件 1083 → 385 行（-64%）。Coordinator 总 LOC +21%（doc-comments
解释 visibility 契约的一次性成本）。

## Phase 29 · 工程化与文档（2026-04-28，commit `21e2479`）

- [x] `.github/workflows/ci.yml` 四道闸：test / release / Swift 6 / strings parity
- [x] `Scripts/check_localization.swift`（en ↔ zh-Hans + dangling reference）
- [x] `Scripts/gen_perf_samples.sh`（1/5/20 MB perf fixtures）
- [x] `Scripts/build_app.sh` LSMinimumSystemVersion 14.0（lockstep with `.macOS(.v14)`）
- [x] README 重写（badges / features / cheat sheet / architecture / i18n / dev）
- [x] ROADMAP 节追加（Phase 15-29 集中纪实 + ADR-006）

## Phase 30 · Markdown 实时预览（2026-04-28，commit `f85d550`）

**目标**：编辑 README/ROADMAP/HANDOFF 时所见即所得，⌘⇧V 切换。

**改动**：
- `Sources/Scribe/Models/MarkdownConverter.swift`（453 行）
  — 纯函数 md → HTML 两阶段扫描器（block: ATX heading / paragraph
  / fenced code / blockquote / list / hr；inline: code / link /
  image / bold / italic / strikethrough，全用 `\u{0001}N\u{0001}`
  占位符保护生成的 HTML 标签不被最终 escape pass 吃掉）。
  v1 范围：CommonMark 子集，不支持表格 / task list / footnote /
  inline HTML。
- `Sources/Scribe/Views/MarkdownPreviewPane.swift`（230 行）
  — `WKWebView` 包装 + GitHub 风格 inline CSS（亮/暗双调色板，
  跟随 SwiftUI `@Environment(\.colorScheme)`）。`window.scrollY`
  跨 reload 持久化，每次按键 50 ms debounce 后局部刷新但不弹回顶。
  `WKNavigationDelegate` 拦截 `<a>` 点击 → `NSWorkspace.shared.open(_:)`
  外部浏览器打开。
- `Sources/Scribe/Models/Document.swift`
  + `@Published var isMarkdownPreviewVisible: Bool`
  + `var isMarkdown: Bool`（沿用 Outline 的 "md" / "markdown" 集合）
- `Sources/Scribe/Views/EditorAreaView.swift`
  EditorAreaView 现在通过私有 `DocumentEditorPane` 间接持 doc 为
  `@ObservedObject`，让 toggle 翻 flag 时 body 重新求值。markdown
  + visible 时画 `HSplitView{ editor | preview minWidth 260 }`。
- `Sources/Scribe/App/AppCommands.swift`
  ⌘⇧V Markdown Preview 菜单项，✓ 当 on，非 markdown doc 时 disabled。
- 新 i18n key `menu.view.markdownPreview` × en/zh-Hans。

**测试**：`Tests/ScribeTests/MarkdownConverterTests.swift` 26 例覆盖：
heading 各级 / 软硬换行 / `***x***` 嵌套 / `snake_case` 不被 italic /
inline code 保护 emphasis / fenced code 含 lang hint + HTML escape +
内部不解析 markdown / 有序/无序/blockquote/list-blank-closes / 链接 /
图片 / `---` 与 `- - -` thematic break / CRLF normalisation /
未闭 fence / 敌意输入 escape / 空输入。

**为什么手写而不用 cmark / Foundation**：Foundation 的 Markdown
API 输出 AttributedString 不是 HTML，覆盖子集还更小；Apple
swift-cmark 加 SwiftPM 依赖。手写 ~400 LOC 比 FFI + 格式翻译更便宜。

## Phase 31 · Git Gutter（2026-04-28，commit `556d2d2`）

**目标**：在编辑器左侧的窄条状 margin 上展示当前文件相对于
HEAD 的行级状态（添加 / 修改 / 删除）。所见即文件改动。

**改动**：
- `Sources/Scribe/Models/GitDiffParser.swift`（150 行）
  — 纯函数 unified-diff → `[LineNumber: GitGutterStatus]`。只读
  hunk header（`@@ -OLDSTART,OLDLEN +NEWSTART,NEWLEN @@`），不解析
  body：四种情况（add / modify / delete / replace）从 OLDLEN /
  NEWLEN 比例就能判出，body 的 `+` `-` 只是给人看的复制品。
  容错：malformed header 静默丢弃；保留 `@@` 后的 section name
  不让它撞坏坐标解析；deletion-at-file-start 的 `newStart=0`
  remap 到第 1 行；多个 hunk 落在同一行时强 status (added /
  modified) 压制弱 status (deletedAbove)。
- `Sources/Scribe/Models/GitGutterEngine.swift`（110 行）
  — `@MainActor ObservableObject`，全工作区单例。`bind(to:)`
  切换文档时立即 refresh，`refresh()` 取消上一在飞 Task 后启
  动 detached `git diff` shell-out → parse → 回 main 写
  `doc.gitGutter`。绑定弱引用，关闭 tab 不留尾巴。
- `Sources/Scribe/Models/GitClient.swift` +`unifiedDiff(of:) ->
  UnifiedDiffResult`：`git diff --no-color --no-ext-diff -U0 HEAD
  -- <path>`，`-U0` 让 hunk 只描述真正变更的行。
- `Sources/Scribe/Views/Scintilla/Coordinator+GitGutter.swift`
  （150 行）— margin 1 = 6 px MARGIN_SYMBOL，三个 marker：
  21 added (FULLRECT 绿) / 22 modified (FULLRECT 黄) / 23
  deletedAbove (LEFTRECT 红 sliver)。`SETMARGINMASKN` 隔离
  其它 marker。`lastAppliedGitGutter` 缓存避免无变更 tick 的
  O(line-count) 重绘。
- `Sources/Scribe/Models/Workspace.swift`
  + `let gitGutterEngine = GitGutterEngine()`
  + `selectionSink` 在 selectedID 变化时 `engine.bind(to: current)`
  + `write(doc:to:)` / `handleExternalChange(of:)` 末尾
    `engine.refresh()`（仅当 doc 是 selected）
- `Sources/Scribe/Models/Document.swift`
  + `@Published var gitGutter: [Int: GitGutterStatus] = [:]`

**测试**：`Tests/ScribeTests/GitDiffParserTests.swift` 11 例覆盖：
empty / header-only / pure-add / single-line addition (length 1
默认) / pure-delete / delete-at-file-start / replacement / 三 hunk
合并 (add + modify + delete) / malformed header tolerance / `@@`
后 section name suffix tolerance / 强 status 压弱 status。

**为什么 git CLI 而不是 libgit2**：用户的 mac 已经有 git，
`/usr/bin/git` 二进制稳定，不增 SwiftPM 依赖，三个操作（locate
repo / read HEAD blob / unified diff）一共 ~30 行 glue。

**为什么对比 working tree 而不是 buffer**：v1 `git diff` 看磁盘
文件，gutter 在保存后才更新。这与「macOS 习惯：改了未存就保存」
吻合。Phase 31b 想做 buffer-aware 的话，HEAD blob ↔ in-memory
text 用现有 LCS 算（DiffSession 已有）。

## Phase 31b · Git Gutter Hunk Navigation（2026-04-28，commit `eeb0adf`）

**目标**：⌥⇧↓ / ⌥⇧↑ 跳到下一个/上一个 git 变更块。
顶下环绕换行，清洁文件上 beep 不静默。

**改动**：
- `Sources/Scribe/Models/GitGutterHunks.swift`（85 行）
  — `groups(in:)` 合并连续行为 `[ClosedRange<Int>]`；status
  类型不参与 grouping，相邻 add/modify/delete 合为一个可跳转
  块（与 VSCode / GitHub 同语义）。`next(after:)` / `previous
  (before:)` 均以「cursor 在 hunk 内 → 跳过整个 hunk」为
  主语义（firstIndex(where: contains)），wrap top↔bottom 与
  Find Next / multi-cursor next match 一致。
- `Sources/Scribe/Models/FindState.swift`
  + `Command.gotoNextHunk` / `Command.gotoPrevHunk`。走现有
  PassthroughSubject 总线，免新增 Combine 订阅。
- `Sources/Scribe/Views/Scintilla/Coordinator+GitGutter.swift`
  + `gotoNextHunk(in:)` / `gotoPrevHunk(in:)`。拿 caret 1-based
  line 调 GitGutterHunks 拿 target 后 `SCI_GOTOLINE` +
  `SCI_SCROLLCARET`。`doc.gitGutter` 空 → NSSound.beep()。
- `Sources/Scribe/App/AppCommands.swift`
  + Tools 菜单 Next/Previous Git Change 菜单项 ⌥⇧↓ / ⌥⇧↑。
  跳过选 ⌘⌥↓ / ⌘⌥↑ （addCaretBelow/Above）以免冲突。
- `Sources/Scribe/Resources/{en,zh-Hans}.lproj/Localizable.strings`
  + `menu.tools.nextHunk` / `menu.tools.prevHunk`

**测试**：`Tests/ScribeTests/GitGutterHunksTests.swift` 14 例覆盖：
empty / single-line / contiguous / gap-of-1-splits / mixed-shape /
ascending-sort 合计 6 例 grouping；next()  empty / 跳过-当前hunk /
before-first / wrap-past-last 4 例；previous() 同样 4 例。

## Phase 32 · Markdown Preview v2（2026-04-28，commit `92201f6`）

**目标**：手写 converter 纳入 GFM 三大世人问场频最高的
扩展：表格 · task list · footnote。零依赖。

**改动**：
- `Sources/Scribe/Models/MarkdownConverter.swift`（+456 行）
  + `BlockContext.pendingTableHeader` 1-line lookahead state。
  pipe 行只有在下一行是 `| --- | :-: |` 对齐行时才转
  table，否则 fallback 为 paragraph。
  + `BlockContext.tableAlignments: [TableAlign]?`、`openTable` /
  `appendTableRow` / `closeTable` helpers。
  + `lineLooksLikeOtherBlock(line:trimmed:)` 闸门：`> | a |`
  、`- | a |`、`## | a |` 不会被表格权走。
  + `matchTaskMarker(_:)` 检测 `[ ] ` / `[x] ` / `[X] `，输出
  `<li class="task-list-item"><input type="checkbox" disabled
  checked?/>...</li>`。Mixed list 可默认出现。
  + `extractFootnotes(from:)` 二走扫描：
     · 一走：`[^id]: text` 定义被提取 + 原行置空（不让
       paragraph state 机处理该行）。
     · 二走：按出现顺序为有定义的引用打编号。
  + `renderInline(_:footnoteRefs:)` optional 参数接收 `[id: num]`
  映射，生成 `<sup class="footnote-ref">[N]</sup>` + 双向锚
  点。未匹配 def 的 ref 保留字面。
  + `renderFootnoteSection(refs:defs:)` 生成底部 `<section
  class="footnotes"><hr/><ol>...↩</ol></section>`，仅在有
  ref+def 配对时输出。
  + `TableAlign` enum (none/left/right/center) + `styleAttr`
  inline `text-align:` 属性。
- `Sources/Scribe/Views/MarkdownPreviewPane.swift`
  + table chrome CSS (border-collapse · alt-row stripe)
  + task list 去 bullet + checkbox vertical-align middle
  + footnote section 与 back-link 调调颜色

**测试**：`MarkdownConverterTests.swift` +18 例（3表 + 5多表
 + 5 task + 5 footnote）达 44/44。涵盖：对齐列颜色 / inline
 emphasis / 短行右补空 / 空行结束 / 伪-pipe-行 paragraph fallback
 / blockquote+pipe 保住 / Mixed task list / 上大小X / footnote 路
  引用顺序 / orphan ref + orphan def / def 内 emphasis / EOF 调度。

**不在 v2范围**：代码块语法高亮（需 Prism.js / highlight.js 嵌
入）、mermaid（需 mermaid.js）、GFM autolinks、行内 HTML、setext
headings、引用式链接。都是 v3 画饱。

## Phase 33 · Snippets v1（2026-04-28，commit `5e70a25`）

**目标**：用户可管理的文本插入模板。⌘⇧T 弹出 fuzzy
选择器（复用 PaletteWindowController），选中按 Enter 在
当前 caret 插入 body；多光标下自动多点插入。Settings →
代码片段 tab 增/删/改，输入即存 UserDefaults。零依赖。

**改动**：
- `Sources/Scribe/Models/Snippet.swift`（50 行）
  Codable struct：id / name / prefix / body / description。Sendable
  跨 actor 传递；Identifiable 为 SwiftUI 列表提供稳定驼峰。
- `Sources/Scribe/Models/SnippetCatalog.swift`（135 行）
  `@MainActor ObservableObject`，单键 UserDefaults JSON 存储
  以原子写避免抖动 save。提供 add/update/remove/
  resetToStarter；包含 5 个 starter snippets 作为首启动生友型。
  Corrupt JSON 同样 fallback 到 seed，不会 panic。
- `Sources/Scribe/Views/SnippetController.swift`（110 行）
  单例，把 snippets 包装为 `ScribeCommand` 填进私有
  CommandRegistry，调 `PaletteWindowController.show(...)` 复用
  现成 fuzzy match UI。多行 body 在 palette 列表以 `head
  line ↵ +N more` 预览。选中后走 `findState.commands.send
  (.insertSnippet(body))`。
- `Sources/Scribe/Models/FindState.swift`
  + `Command.insertSnippet(String)`。与 test-only 的
  insertAtCarets 区开，使 case 标签能说明这是面向用户的
  路径。最终都走同一条 SCI_INSERTTEXT walk。
- `Sources/Scribe/Views/ScintillaCodeEditor.swift`
  Coordinator sink 加 case `.insertSnippet → insertAtCarets`。
  复用现有多光标路径，零成本拿到 multi-cursor 插入能力。
- `Sources/Scribe/Views/SettingsView.swift`（+220 行）
  新 `SnippetsSettingsPane`：HStack(侧栏列表, 分隔线, 详情
  表单)。Add/delete/reset 按钮 + reset 的确认 alert。表单
  字段全部是 computed `Binding<Snippet>`，插件式走 `catalog
  .update(...)` “输入即存”。面板宽高 540×380 → 720×460 以容
  多行 body editor。
- `Sources/Scribe/App/AppCommands.swift`
  + Edit 菜单 "Insert Snippet…" ⌘⇧T，在 Find-in-Files 后、
  Hide Find Bar 前。无 doc 时禁用。`ScribeCommands` 增
  `snippets: SnippetCatalog` 参数。
- `Sources/Scribe/ScribeApp.swift`
  + `@StateObject snippets = SnippetCatalog()` · `.environmentObject
  (snippets)` 为 MainWindow 与 Settings scene · 给 ScribeCommands
  传参。
- `Sources/Scribe/Resources/{en,zh-Hans}.lproj/Localizable.strings`
  + 21 个新 key：`menu.edit.insertSnippet` · `snippet.palette.*` ·
  `settings.tab.snippets` · `settings.snippets.*`

**测试**：`SnippetCatalogTests.swift` 9 例：first-run-seeds-defaults
 / second-instance-loads-persisted / add·update·remove / update-unknown-
id-noop / reset-replaces-user-snippets / Snippet Codable round-trip
 / 损坏 JSON fallback 到 seed。使用独立 UserDefaults suite 避免
跨测试污染。

**不在 v1 范围**：`${1:placeholder}` 占位跳转（需跨 caret 会
话）、Tab 键从 buffer 文本触发（需 Scintilla autocomplete
接入）、按语言 scope（现代码片段对所有文档可见）、导入/导出
JSON 文件（UserDefaults 是唯一存储）。均为 v2 画饱。

## Phase 34a · LargeFile Loader Plumbing（2026-04-28，commit `32c5433`）

**目标**：ndd C++ 核心移植的第一拍。低风险上手：
先全部为 chunked-load 需要的零件落地，不接 production 路径。单
个 commit 小且独立，API 在 production 接入前被 tests 映射。

**改动**：
- `Vendor/scintilla/include/ScribeScintillaLoaderBridge.h` ·
  `Vendor/scintilla/swiftpm-bridge/ScribeScintillaLoaderBridge.mm`
  ObjC++ 面板调 `Scintilla::ILoader` 的 AddData / Convert /
  Release。镜像 Lexilla 项目同样位置的 LexillaBridge。
- `Vendor/scintilla/include/ScribeScintillaUmbrella.h` 里面 +
  `#import "ScribeScintillaLoaderBridge.h"`。
- `Package.swift`: Scintilla target sources 加 `swiftpm-bridge`。
- `Sources/Scribe/Views/Scintilla/SCIConstants.swift`
  + SCI.CREATELOADER / SETDOCPOINTER / RELEASEDOCUMENT /
  ADDREFDOCUMENT message ID。
  + SC.DOCUMENTOPTION_DEFAULT / STYLES_NONE / TEXT_LARGE。
- `Sources/Scribe/Models/LargeFileLoader.swift`（140 行）
  Swift wrapper over ILoader。`@MainActor static allocate
  (on:initialSize:options:)` 为唯一 view-touch。实例
  `@unchecked Sendable` 运行于后台 chunked pipeline。
- `Sources/Scribe/Models/ChunkedFileReader.swift`（100 行）
  mmap-backed `Data(.mappedIfSafe)`，每个块是共享页缓存的 O(1)
  切片。Chunk size 底限 4 KiB 避免 AddData round-trip 抱獞。
- `Sources/Scribe/Models/LargeFilePolicy.swift`（60 行）
  64 MiB 阈值走 chunked。总是 STYLES_NONE。♥1.5 GiB 才翻
  TEXT_LARGE。

**测试**：16 例覆盖：LargeFilePolicyTests (6) / ChunkedFileReader
Tests (8) / LargeFileLoaderTests (2 bridge symbol 可达性)。Live
ILoader 集成 *不* 由 xctest 调 —— ScintillaView.init 在 headless
环境下触 NSCursor 段错（同样约束与 ScintillaBridgeTests）。
活路径 smoke 在 Phase 34b 打开 .app 测。

## Phase 34b · LargeFile Production Path（2026-04-28，commit `67c7343`）

**目标**：把 Phase 34a 零件接到发送路径。≥ 64 MiB 的文件现在
走 SCI_CREATELOADER → chunked AddData → SCI_SETDOCPOINTER 路径，
不再 materialise 为 Swift `String`。状态栏为 load 中文件显
示“正在加载大文件…” affordance。

**改动**：
- `Sources/Scribe/Models/Document.swift`
  + `@Published var isLargeFile: Bool = false`
  + `@Published var loadProgress: Double = -1`
  Documented contract：`doc.text` 对 large doc 始终为空；Find /
  Markdown / git-gutter 读 `text` 在该场景下静默 no-op，未来
  Phase 34c 教它们走 SCI_GETTEXTRANGE 读 Scintilla buffer。
- `Sources/Scribe/Models/Workspace.swift`
  `openFile` 在启 async 加载前跳个快速文件大小探针。
  超阈值 → 打 isLargeFile=true / loadProgress=0、不启
  loadAndDecode 、 return。小文件继续走原 String 路径。
- `Sources/Scribe/Views/Scintilla/Coordinator+LargeFile.swift`（210 行）
  - main: LargeFileLoader.allocate 唯一 view-touch。
  - detached Task: ChunkedFileReader.forEachChunk → loader.addChunk
    → loader.convertToDocument。返回 doc-pointer **以 Int** 带词
    pattern 横跨 actor 边界（`UnsafeMutableRawPointer` 不
    Sendable 下严格并发 mode）。
  - main: SCI_SETDOCPOINTER lparam=address，翻主
    loadProgress=1 / isLoading=false。
  - Document-swap guard：载中用户切了 doc → SCI_RELEASEDOCUMENT
    “孤儿”文档，不踩前台。
  - 失败路径＞alloc / AddData / Convert / readFailed 都 cancel
    loader · isLargeFile=false，用户可重开走原路径。
- `Sources/Scribe/Views/ScintillaCodeEditor.swift`
  + Coordinator.largeFileLoadStarted 防重入闸门。
  + makeNSView 末尾调 `beginLargeFileLoadIfNeeded`。
- `Sources/Scribe/Views/StatusBarView.swift`
  + Loading banner：ProgressView + "status.largeFileLoading"。位于
  modified 指示之前，优先级边检点。
- `Sources/Scribe/Resources/{en,zh-Hans}.lproj/Localizable.strings`
  + `status.largeFileLoading`。

**未覆盖 (Phase 34c+)**：中途 cancel UX、细粒度 progress
汇报、Find/Markdown/git-gutter 读 Scintilla buffer、大文件写路
径（SCI_GETTEXTRANGE 分块 save）。

## Phase 34c · LargeFile v2 — chunked save + OOM 护栏（2026-04-28，commit `c678b67`）

**背景**：Phase 34a/34b 只交付加载。这拍如果不补，1 GB
文件会在三个地方出事：(1) ⌘S 写空 buffer（`doc.text=""`）——
实际数据丢失；(2) 每次光标移动 SwiftUI 调 updateNSView 里走
到1.5 GB Swift String 允率 OOM；(3) 状态栏报“0 chars”误
导用户。三个 CRIT 全补。

**改动**：
- `Vendor/scintilla/include/ScribeScintillaTextRangeBridge.h` ·
  `Vendor/scintilla/swiftpm-bridge/ScribeScintillaTextRangeBridge.mm`
  ObjC++ 面板包 SCI_GETTEXTRANGEFULL。`NSData *Scribe
  ReadTextRange(view, start, length)`。`Sci_TextRangeFull` 用
  Sci_Position（64-bit ptrdiff_t）保证 > 2 GB 读取安全。
- `Sources/Scribe/Models/ChunkedFileWriter.swift`（190 行）
  `@MainActor write(view:to:byteCount:progress:)`。256 KiB chunk
  （4 KiB 底限、与 reader 收同）。同盘 sibling temp + 
  rename。`synchronize()` fsync 后再 rename，避免断电后藏半个文
  件在 page cache。各块间 `Task.yield()` 不锁住 run loop。
  失败模式：openTempFailed / writeFailed / readFailed /
  replaceFailed —— 全部原子以防部分赋赋。
- `Sources/Scribe/Models/Document.swift`
  + `largeFileSaveHook: (URL, (@MainActor (Double) -> Void)?)
    async throws -> Void` —— Coordinator.attach 调装。合 phase
    28c 的 `flushPendingEdit` 同模。
  + `@Published var saveProgress: Double = -1`。
- `Sources/Scribe/Models/Workspace.swift`
  + `write(doc:to:)` 检 isLargeFile 走 chunked save。防重入 +
  异步 Task + saveProgress 。小文件走原路径不变。
  + `handleExternalChange` 大文件父 no-op（不能读整个文件
  去比 doc.text）。v2 上 mtime + size check。
- `Sources/Scribe/Views/ScintillaCodeEditor.swift`
  + `if !doc.isLargeFile { ... }` 不 resync 大文件（CRIT #2）。
  + `flushDocSync` / `scheduleDocSync` 大文件 early-return。
  + Coordinator.attach 装上 `largeFileSaveHook`。
- `Sources/Scribe/Views/StatusBarView.swift`
  + Save banner（linear ProgressView + “正在保存大文件…”）。
  + `largeFileSizeLabel(for:)` 大文件 charCount 处换为
  ByteCountFormatter 人读文件大小。
- `Sources/Scribe/Resources/{en,zh-Hans}.lproj/Localizable.strings`
  + status.largeFileSaving / status.largeFile
  + error.largeFileSaveNoEditor

**测试**：6 例覆盖 ChunkedFileWriter：bridge 符号可达 + nil/0
边界 · 4 KiB chunk size floor · default 256 KiB · 空文档快路径
· ChunkedFileWriterError Sendable。Live SCI_GETTEXTRANGEFULL 集
成 *不* 由 xctest 调 —— ScintillaView.init headless segfault
同 LargeFileLoaderTests。

**未覆盖 (Phase 34d+)**：中途 cancel save UX、external-change
大文件 mtime+size diff、SymbolOutline / Markdown preview 读
大文件 buffer。

## Phase 35a · scribe CLI shim（2026-04-28，commit `a7f96f7`）

**背景**：zed 调研后的 detour —— zed 文档表面上主打
协作/AI/CRDT/GPUI，但那些架构选择对一个 Scintilla
后端的编辑器不适用。真正高 ROI 取经点为“现代编辑器
都有 CLI shim”这个期望。没有它 Scribe 体现不了 `git
core.editor`、从脚本调不动、要记 SCRIBE_AUTO_* env knob。

**交付**：
- `Scripts/scribe`（210 行 bash + chmod +x）
  Argv 解析 → SCRIBE_AUTO_* env → `open -a Scribe.app`。接口
  对齐 zed verbs：
  - `-h/--help`、`-v/--version`
  - `-w/--wait` · 适用 `git core.editor`（v1 用
    `open -W -n`，冷启动；v2 上 IPC fifo）
  - `-n/--new` 强制新实例
  - `-l/--line N` · 1-based、在解析时拒绝 0 / 负 / 非数
  - `-d/--diff A B` · 塑 SCRIBE_AUTO_COMPARE
  - `--` stop flag，支持 `-` 开头的文件名
  路径统一补全为绝对 ($PWD)，SwiftUI app 进程的 CWD 与
  shell 不同，不补全会错错。
- `Sources/Scribe/App/StartupEnvironment.swift`
  + `autoOpenLine: Int?` 字段·从 SCRIBE_AUTO_OPEN_LINE 读取·
    严格正整验证（0 / 负 / 非数 都 silently drop）。
  + `StartupAutoOpen.apply` 传给 `workspace.openFile(at:line:)`。
    多文件共享同一 line，同 `code -g` / `subl -l`。
- `Tests/ScribeTests/ScribeCLITests.swift`（9 cases）
  以 Process 调 wrapper · verify exit code / stdout / stderr。
  覆盖 --version / --help / --line missing/bad/0/-5 / --diff
  one-arg / unknown flag。不调实际 `open`（CI headless）。
- `README.md`：Quick Start 下增“使用 scribe CLI (Phase 35a)”
  子段·symlink 安装 · 用例 · v1 限制说明。

**未覆盖 (Phase 35b+)**：IPC fifo 让已运行实例也能 wait、
brew formula、bash/zsh completion script。

## Phase 35b-1 · Source Control sidebar（2026-04-28，commit `ab8e21a`）

**背景**：zed “Git Panel” 是调研交财点出的最高 ROI。这拍交付读面
—— 侧栏 tab + 数据层 + UI 行。per-hunk stage/unstage · commit 留
给 35b-2/3。

**交付**：
- `Sources/Scribe/Models/GitStatus.swift`（140 行）·GitFileStatus value
  type · GitChangeKind enum (porcelain v1 codes + `.unknown`) ·
  computed flags `isConflict` / `hasStagedChanges` / `hasUnstagedChanges` /
  `isUntracked`
- `Sources/Scribe/Models/GitStatusParser.swift`（80 行）·纯函数
  · 解 `git status -z --porcelain=v1` · NUL 分隔 · R/C 吃 origin
  path · path 保原（不 shell unquote）·未知 code 不崩
- `Sources/Scribe/Models/GitClient.swift` + `StatusResult` enum +
  `static func status(repo:)`（复用现有 run）
- `Sources/Scribe/Models/GitStatusEngine.swift`（120 行）·与 Gutter
  Engine 同模 · 三状态 idle/notInRepo/loaded · detached Task
  cancel & replace · transient error 保留先前 rows
- `Sources/Scribe/Models/Workspace.swift` + SidebarMode.sourceControl
  + GitStatusEngine instance + openFolder/closeFolder bind +
  save/handleExternalChange refresh hooks
- `Sources/Scribe/Views/SourceControlSidebar.swift`（210 行）·分段
  Conflicts/Staged/Changes/Untracked（红绿橙灰 zed 颜色语法）
  · 点行 → openFile · 三个空状态 copy
- `Sources/Scribe/Views/SidebarView.swift` + mode 按钮
  "arrow.triangle.branch" + switch case
- `Sources/Scribe/Resources/{en,zh-Hans}.lproj/Localizable.strings`
  + sidebar.mode.sourceControl + sourceControl.empty.* + .section.*

**测试**：16 闸覆盖 GitStatusParser：empty/空 NUL/短 entry/上下
变/conflict 矩阵 (UU/AA/DU)/rename 吾 origin/copy 同/multi-entry
顺序/path absolute · path 含空格 · unknown code。Live `git status`
集成 不 由 xctest调 —— engine 热路径只是 Process + Parser，
纯函数部分全面覆盖。

**未覆盖 (Phase 35b-2 / 35b-3)**：per-hunk stage/unstage、commit
message textarea · push/pull/fetch 按钮、Project Diff multibuffer
（zed 可编辑 diff excerpts）、Inline blame + merge UI（Phase 35c）。

## Phase 35b-2a · Source Control row actions（2026-04-28，commit `b1d34ea`）

**背景**：35b-1 交付了读面，这拍交付 file-level 写面
—— hover row 出 [discard]/[+stage]/[-unstage]。zed/VSCode 同
样 hover-cluster 模式。

**交付**：
- `Sources/Scribe/Models/GitClient.swift` + `WriteResult` (Sendable
  + Equatable) + `stage(path:repo:)` / `unstage(path:repo:)` /
  `discardWorkingTree(path:repo:)`。3 个都是 nonisolated
  static。zed/git-docs 推荐 `git restore --staged` 而非
  古 `git reset HEAD --`，同采用。
- `Sources/Scribe/Models/GitStatusEngine.swift` + `import AppKit`
  + `stage(_:) / unstage(_:) / discard(_:) async` · detached
  Task pipeline · untracked discard 走 FileManager.removeItem
  (git 没东西可 restore) · WriteAction enum + handleWriteResult
  on 错误 弹 NSAlert（用 sourceControl.alert.* i18n key）·
  无论成败 refresh()。
- `Sources/Scribe/Views/SourceControlSidebar.swift` + SourceControlRow
  拿 engine · hover 出 rowActions：discard 总显 · unstage 仅
  hasStagedChanges · stage 仅 hasUnstagedChanges 或 isUntracked
  · "AM" 同时显 + 和 - · discard 走 NSAlert 二次确认 +
  hasDestructiveAction。
- `Sources/Scribe/Resources/{en,zh-Hans}.lproj/Localizable.strings`
  + sourceControl.action.{stage,unstage,discard} +
  .discard.confirm.{title,message} + .alert.{stage,unstage,discard}Failed
  + alert.button.ok。

**测试**：5 闸集成 · 每次在
`NSTemporaryDirectory/scribe-git-write-<UUID>` 建 scratch repo
· stage " M"→"M " · stage "??"→"A " · unstage "M "→" M" ·
discardWorkingTree restore + status 空 · 重调幂等。
`XCTSkipUnless /usr/bin/git`。

**未覆盖 (Phase 35b-2b / 2c / 35b-3)**：commit message textarea +
Commit/Amend、push/pull/fetch + branch indicator、per-hunk stage
(`git apply --cached <patch>`)、Project Diff multibuffer。

## Phase 35b-2b · commit panel · branch indicator（2026-04-28，commit `7bf4e72`）

**背景**：35b-1/2a 交付读面 + file-level 写面，这拍交付
提交面本身—— 侧栏底部 multi-line TextEditor + Amend toggle
+ Commit 按钮（⌘⏎）+ 顶部分支指示器。用户不出 Scribe 就
能完成 add-commit 闭环。

**交付**：
- `Sources/Scribe/Models/GitClient.swift` + `commit(message:repo:amend:)`
  走 stdin 递送（`-F -`）· zed/GitHub Desktop 同推荐，
  避开 macOS argv ~256 KiB 上限 · `--cleanup=strip`。
- `Sources/Scribe/Models/GitClient.swift` + `currentBranch(repo:)` /
  `headSubject(repo:)` + private `runWithStdin(_:stdin:cwd:)` helper。
  拆出 stdin 路径避免读代码路径多走个不用的参数。
- `Sources/Scribe/Models/GitStatusEngine.swift` + `@Published branch:
  String?` (refresh 同一拉 status + branch) + `headSubject` 计算 ·
  `commit(message:amend:) async` · WriteAction.commit case +
  sourceControl.alert.commitFailed。
- `Sources/Scribe/Views/SourceControlSidebar.swift` + branchHeader
  + commitPanel：TextEditor (multi-line, placeholder overlay) +
  Amend toggle（开启 预填 headSubject 仅在草稿空时不覆盖输入）·
  Commit 按钮 .borderedProminent · ⌘⏎ 快捷键 · disabled
  锁：空消息 或 (非 amend 且 staged=0) · 提交后启发式清草稿
  · 隐藏在 .idle / .notInRepo。
- `Sources/Scribe/Resources/{en,zh-Hans}.lproj/Localizable.strings`
  + sourceControl.branch.detached + .commit.{placeholder, placeholder.amend,
  amend, action, amend.action, shortcut.hint} + .alert.commitFailed。

**测试**：+5 闸 (总 10) · commit 后 tree 空 + headSubject 一致 ·
amend 不增加 commit count + 主题重写 · Unicode/多行体 stdin
贯顺 · currentBranch 与 `git branch --show-current` 一致 ·
游离 HEAD 返 nil。

**未覆盖 (Phase 35b-2c / 35b-3)**：push/pull/fetch + ahead/behind
indicator、remote branch picker、per-hunk stage (`git apply
--cached <patch>`)、Project Diff multibuffer。

## Phase 35b-2c · remote sync（2026-04-28，commit `eab2dd0`）

**背景**：35b-2b 交付 commit 面，这拍闭环：侧栏顶部 ahead/
behind 胶囊 + fetch / pull / push 三按钮。推送环节不出
Scribe。

**交付**：
- `Sources/Scribe/Models/GitClient.swift` + `AheadBehind { ahead,
  behind }` (Sendable + Equatable，带 isUpToDate / diverged) ·
  fetch/pull/push (`git fetch --quiet` / `git pull --ff-only` /
  `git push --quiet`) · aheadBehind(repo:) 走 `git rev-list
  --left-right --count HEAD...@{upstream}` · parseAheadBehind 纯
  函数（tab-separated 与 column-aligned 两种 shape 统一走
  whitespace-split）。`--ff-only` 是故意：非 fast-forward
  走 rebase 还是 merge 该是主动选择，不能点按钮手滑。
- `Sources/Scribe/Models/GitStatusEngine.swift` + `@Published
  aheadBehind: AheadBehind?` (refresh 同拉 status + branch +
  ab) · `fetch() / pull() / push() async` · WriteAction
  .{fetch,pull,push} cases + `sourceControl.alert.{fetch,pull,
  push}Failed`。
- `Sources/Scribe/Views/SourceControlSidebar.swift` branchHeader
  扩：分支名 · ahead/behind capsule（仅 non-nil & 非 0/0 显）
  · fetch/pull/push 3 borderless icon 按钮 · push glyph 在
  ahead>0 时 swap .fill 变体。remoteButton helper 塑体与
  35b-2a row-action cluster 一致。
- `Sources/Scribe/Resources/{en,zh-Hans}.lproj/Localizable.strings`
  + sourceControl.action.{fetch,pull,push} + .alert.{fetch,pull,
  push}Failed。

**测试**：+10 闸 (总 26 个 Source Control test)。`GitAheadBehindParserTests`
纯函数 6 闸（tab/space/0·0/发散/空/畸形）· +4 integration
(`bare init` + `git push -u` + sibling clone 模拟 remote 推送后
拉取 round-trip)。走 `XCTSkipUnless /usr/bin/git`。

**未覆盖 (Phase 35b-3 / 35c / 后续)**：per-hunk stage (`git
apply --cached <patch>`)、Project Diff multibuffer、remote
branch picker、`--force-with-lease` push UX、inline blame +
merge conflict UI。

## Phase 35+ · 路线展望

下面是想做的事，按重要度而非时间排。多条路线是 zed 调研后决定插入的。

1. **Git v2 (Phase 35b-3 / 35b-4)**：per-hunk stage/unstage (`git apply --cached`) + Project Diff multibuffer + remote branch picker。Phase 35b-1/2a/2b/2c 交付了读面 + file-level 写面 + commit + remote sync 闭环。
2. **Inline Git Blame + Merge Conflict UI (Phase 35c)**：行末 annotation 显示 author/time/commit、冲突区上方 Accept/Reject 按钮。复用现有 GitClient。
3. **LargeFile v3 (Phase 34d+)**：中途 cancel save、external-change
   mtime+size detection、SymbolOutline 读 buffer、细粒度 progress。
4. **CLI shim v2 (Phase 35d+)**：IPC fifo 让 `--wait` 不再冷启动、bash/zsh completion、brew formula。
5. **Document Map**：右侧缩略图侧栏（学 npp-mac，仅 SwiftUI）。
6. **Snippets v2**：`${1:placeholder}` 跳转 + tab 键从 buffer 触发（Scintilla autocomplete） + per-language scope。
7. **Markdown Preview v3**：代码块语法高亮 + mermaid 图。
8. **HEX View**：参考 ndd 的 `HEXMode.cpp`。
9. **官方 disk image** + Sparkle 自动更新。

---

## ADR-006 · Swift 6 严格并发是不退让基线
**日期**：2026-04-28  
**触发**：Phase 28 修完一轮严格并发错误。  
**决策**：CI 强制 `swift build -Xswiftc -swift-version -Xswiftc 6` 全绿（Vendor/ 除外）。  
**原因**：
1. 严格并发是 Swift 长期方向，被动跟进迟早要修，不如一次性硬化
2. 现在的代码量（~30 KLoC）是修战迹 cost 最低的时机
3. 严格并发暴露的 bug 多数是 latent 的——FSEvents 回调跨线程、`NSApp` 访问跨 actor——这些以后会以 nondeterministic crash 形式爆出来  
**代价**：偶尔需要额外的 `@MainActor` / `nonisolated` 注解 + `Task` shape 调整。已被 Phase 28 / 28b 验证可控。

## ADR-007 · 性能用绝对预算，不用 baseline
**日期**：2026-04-28  
**触发**：写 PerformanceTests.swift 时考虑过 XCTest 的 `measure { }`。  
**决策**：用 wall-clock 绝对预算（"openFile sync 部分 < 50 ms"），不用 measure baseline。  
**原因**：
1. baseline 文件 per-machine，CI runner 与本机硬件差异会让 `measure` 误报
2. 用户感知的是"没卡"还是"卡了"——绝对阈值正好对应用户体验
3. 预算超了说明回归，明确不需要解读"95th percentile 多快"  
**代价**：不能 track 微小渐进改进（measure 能）。可接受——大改进自然会一眼看出。
