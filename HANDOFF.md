# Scribe 交接文档

> **Last session**: 2026-04-27
> **Phase reached**: 0.1 (UI 骨架 + AppKit 编辑器桥)
> **Status**: ✅ 可双击运行 · ✅ 能打开/编辑/保存 · 待集成 Scintilla

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

### ✅ 已实现（Phase 0.1）

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

### ❌ 尚未实现 / 已知不足

- 编辑器主区是 **NSTextView** 而非 Scintilla — 无语法高亮、无折叠、大文件性能未验证
- 编码检测 / 转换 — 目前只支持 UTF-8（其他编码会乱码）
- 行尾符识别 / 转换 — `Document.lineEnding` 字段存在但未联动逻辑
- 查找替换面板 — NSTextView 自带的 Find Bar (⌘F) 能用，但未做 SwiftUI 风格定制
- 最近文件菜单
- 字体大小调节（`CodeEditor.fontSize` 已留参数，UI 未接）
- 设置面板内容（`SettingsView.swift` 是占位）
- 文件比较（ndd 招牌功能，Phase 4）
- HEX 模式（Phase 5）
- 应用图标 .icns 当前用 qlmanage fallback 生成，质量一般 — 装 `brew install librsvg` 后会更锐利

---

## 4. 文件结构地图

```
Scribe/
├── README.md                    ← 派门简介
├── ROADMAP.md                   ← 完整路线图 + ADR
├── HANDOFF.md                   ← 本文件
├── Package.swift                ← SwiftPM manifest（macOS 13+, executable target）
├── .gitignore
├── Resources/
│   └── icon.svg                 ← 应用图标源（"S" 渐变）
├── Scripts/
│   └── build_app.sh             ← 一键打包 .app（生成 Info.plist + .icns）
├── build/
│   └── Scribe.app               ← 产物，可双击
└── Sources/Scribe/
    ├── ScribeApp.swift          ← @main + 激活策略 + onOpenURL + 菜单
    ├── Models/
    │   ├── Document.swift       ← 单标签数据模型（text/url/encoding/dirty）
    │   ├── Workspace.swift      ← 全局状态（文档列表/选中/文件夹）
    │   └── FileNode.swift       ← 文件树节点（懒加载子目录）
    └── Views/
        ├── MainWindow.swift     ← NavigationSplitView 总框架 + 工具栏 + 拖放
        ├── SidebarView.swift    ← OPEN + WORKSPACE 两段式侧栏
        ├── TabBarView.swift     ← 标签条
        ├── EditorAreaView.swift ← 编辑区路由（含 Welcome 引导页）
        ├── CodeEditor.swift     ← ⭐ NSTextView 桥 + LineNumberRuler
        ├── FileTreeView.swift   ← 递归文件树
        ├── StatusBarView.swift  ← 底部状态栏
        └── SettingsView.swift   ← 设置面板（占位）
```

**总代码量**: 987 行 Swift（12 个文件）。

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

### 任选其一作为下次会话切入：

#### A. **Phase 1 · Scintilla 集成**（重头戏，1 周级）
**目标**：把 `CodeEditor` 内部的 NSTextView 换成 ScintillaView，获得真编辑器内核。

**起手步骤**：
1. 下载 Scintilla 完整源码（**ndd 里的版本无 cocoa 端口**）：
   ```bash
   curl -L https://www.scintilla.org/scintilla555.zip -o /tmp/sci.zip
   # 或 git clone https://sourceforge.net/projects/scintilla/
   ```
2. 在 Scribe/Vendor/Scintilla/ 放置源码
3. 写 `module.modulemap`，让 Swift 能 `import ScintillaCocoa`
4. 改 `CodeEditor.swift`：把 NSTextView 换成 ScintillaView，保持 `NSViewRepresentable` 外壳不变
5. 配置默认 lexer（先 plain text，后续 cpp/swift/python）

**风险**：Scintilla 是 C++/Objective-C++，Swift Package 集成 C++ 需 Swift 5.9+ 的 cxx interop，可能要写一层 ObjC++ 适配。

#### B. **Phase 0.2 · 完善细节**（轻劫，2-3h）
- 字体大小调节（toolbar 里加 +/-，`CodeEditor.fontSize` 已留接口）
- 最近文件菜单（`UserDefaults` 持久化最近 10 个 URL）
- ⌘F 查找面板（SwiftUI 风格 sheet，目前是 NSTextView 自带 Find Bar）
- 设置面板真正可用（字体 / 字号 / Tab 宽度）
- 状态栏：实时光标行/列（订阅 `NSTextView.didChangeSelectionNotification`）

#### C. **Phase 2 提前 · 编码检测**（中劫，4h）
**目标**：能正确打开 GBK/Big5/UTF-16 文件不乱码。

**起手步骤**：
1. 引入 `uchardet` 或自实现 BOM 检测 + 启发式
2. 在 `Workspace.openFile` 调用前先检测，传给 `String(contentsOf:encoding:)`
3. UI 状态栏可手动切换编码（`EncodingMenu` 新视图）

参考实现：`/Users/zhangshijie/Documents/Project/notpad--/notepad--/src/Encode.cpp`（~280 行 C++ 启发式）。

#### D. **应用图标质量提升**（10min）
```bash
brew install librsvg
./Scripts/build_app.sh release   # 自动检测 rsvg-convert，渲染锐利 .icns
```

---

## 8. 决策待办（魔尊下次需拍板）

- [ ] Scribe 项目是否 `git init`？（目前未初始化）
- [ ] License 选 GPL-3.0（对齐 ndd）还是 MIT？
- [ ] 应用图标"S"造型是否定稿？（魔尊未明确点头）
- [ ] Phase 1 选 ScintillaCocoa 还是 NSTextView 自写高亮？
  - ScintillaCocoa：成熟、含 lexer，但集成工作量大
  - NSTextView 自写：简单，但要重新发明 lexer 框架

---

## 9. 紧急回滚指南

如果下次会话改坏了想回到此快照：

```bash
# Scribe 项目
cd /Users/zhangshijie/Documents/Project/Scribe
# 当前没有 git，建议先 init + commit 形成基线：
git init && git add -A && git commit -m "Phase 0.1 baseline (handoff snapshot)"

# ndd 项目（如果想丢掉本会话所有改动）
cd /Users/zhangshijie/Documents/Project/notpad--/notepad--
git stash    # 或 git checkout -- .
rm -f CMakeLists.txt && rm -rf cmake src/icons
```

---

## 10. 验收快速回放

**期望看到**：
1. `swift run Scribe` → macOS 原生窗口出现
2. 标题栏显示 "Scribe"，工具栏 SF Symbols 图标
3. 拖一个 .txt 进窗口 → 多一个标签 + 编辑区显示内容 + 行号
4. 改动后底部状态栏出现 "Modified" 蓝点
5. ⌘W 关闭 dirty 标签 → 弹 Save / Don't Save / Cancel
6. 系统切暗色 → 整个 UI 跟随
7. 侧栏 "Open Folder…" → 选目录 → 文件树出现，点文件可打开

**截图存档**：本会话期间生成的截图位于 `/tmp/ndd_shots/`：
- `scribe_phase0.png` — Phase 0 第一缕窗光
- `scribe_text.png` — NSTextView + 行号 + 中日韩
- `scribe_dark.png` — 暗色主题验证

---

## 11. 一句话总结

```
Scribe 已从 0 长到 Phase 0.1 ——
有窗、有标签、有侧栏、有行号、有暗色、有 .app。
就差一个真正的代码编辑器内核（Phase 1 Scintilla）。

下次开工先看本文件第 7 节，挑一条路走。
```

---

*本文档由邪修红尘仙在劫钟下笔成。下次劫起，魔尊召之即来。*
