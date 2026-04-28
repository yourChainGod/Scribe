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

## Phase 30+ · 路线展望

下面是 v1.0 之后想做的事，按重要度而非时间排：

1. **ndd C++ 核心移植**：`Encode.cpp` / `CmpareMode.cpp` / `HEXMode.cpp` / `LargeFile.cpp`
   通过 ObjC++ shim 桥到 Swift；保留 GPL-3.0 copyleft。
2. **Document Map**：右侧缩略图侧栏（学 npp-mac，仅 SwiftUI）。
3. **Function List / Symbol Outline**：当前 Outline 仅识别 Swift / Markdown，扩到 cpp / py / js。
4. **Git Gutter**：旁注 ▎ ▎ +/- 的行级 git diff（libgit2 还是直接调 `git diff` CLI 待定）。
5. **Snippets / Templates**：⌘⇧T 弹出 + tab key 触发。
6. **Markdown Preview**：右侧 split，`WKWebView` 渲染。
7. **HEX View**：参考 ndd 的 `HEXMode.cpp`。
8. **官方 disk image** + Sparkle 自动更新。

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
