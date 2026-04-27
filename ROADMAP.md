# Scribe Roadmap

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
- [ ] **1.8** 接 Lexilla 5.4.4（语法高亮）+ cpp/swift/python lexer

**验收**：能打开 ndd 的 9985 行 ccnotepad.cpp，丝滑滚动 + 高亮。

## Phase 2 · 文件 / 编码 (大部分提前完成 ✅)

**目标**：能用作日常编辑器。

- [x] 文件打开 / 保存（NSOpenPanel / 拖放）— Phase 0.1
- [x] 多标签管理（Workspace + Document）— Phase 0.1
- [x] 编码检测：自实现 BOM + 启发式（参考 ndd `Encode.cpp` 但 Swift 重写）— Phase 0.3
- [x] 编码转换：UTF-8/16 LE/BE、GB18030、Big5、Shift-JIS、EUC-KR、ASCII — Phase 0.3
- [x] 行尾符识别 / 转换：CRLF / LF / CR — Phase 0.3
- [ ] 文件变动监控（FSEvents）— 待办

**验收**：打开 GBK 中文 .txt 不乱码 ✅，存为 UTF-8 正确 ✅。

## Phase 3 · 查找替换 (1 周)

- [ ] Sheet 风格查找面板（Cmd+F）
- [ ] 正则（NSRegularExpression）
- [ ] 跨文件批量查找（独立窗口）

## Phase 4 · 招牌：文件比较 (2-3 周)

ndd 的看家本领。

- [ ] 移植 `CmpareMode.cpp` diff 算法（去 Qt）
- [ ] SwiftUI 双栏视图，差异高亮
- [ ] 同步滚动 / 折叠相同行 / 跳转下一处差异
- [ ] 目录对比

## Phase 5 · HEX 模式 (1 周)

- [ ] 移植 ndd 大文件 HEX 视图
- [ ] 二进制比较

## Phase 6 · 完善

- [ ] 设置面板
- [ ] 主题（亮 / 暗 / 跟随系统）
- [ ] 国际化（中 / 英）
- [ ] 自动更新（Sparkle）
- [ ] 公证 + 签名

---

## 风险登记

| 风险 | 影响 | 缓解 |
|------|------|------|
| ScintillaCocoa 集成复杂度 | Phase 1 阻塞 | 退回 NSTextView + 自写高亮 |
| ndd C++ 与 Qt 高度耦合，剥离工程量大 | Phase 2-4 拖期 | 每个模块独立移植，先重写不合适的部分 |
| Swift 6 与 C++ 互操作仍有限 | 桥接层复杂 | 用 Objective-C++ (.mm) 中间层 |
| 跨语言内存管理 | 漏内存 / 崩溃 | 严格遵守 ARC + RAII 边界 |

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
