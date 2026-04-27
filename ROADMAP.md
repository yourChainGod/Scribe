# Scribe Roadmap

## Phase 0 · UI 骨架 (current)

**目标**：能跑的最小 SwiftUI macOS 应用，让我们看到美学起点。

- [x] 项目立项：目录结构、README、ROADMAP
- [x] Swift Package + SwiftUI `@main` 入口
- [x] 主窗口骨架：侧栏 / 标签 / 编辑区 / 状态栏
- [x] 编辑区使用 SwiftUI `TextEditor` 占位
- [x] `swift run` 能启动并显示主窗口

**验收**：截图。窗口起来，UI 齐整，能输入字符。

## Phase 1 · Scintilla 集成 (1 周)

**目标**：替换占位 TextEditor 为生产级编辑器。

- [ ] 引入 ScintillaCocoa（Scintilla 官方 Cocoa 端口）
- [ ] Swift `NSViewRepresentable` 包装 `ScintillaView`
- [ ] 行号、代码折叠、缩进引导
- [ ] 基础语法高亮（Lexer 选择）
- [ ] 与 SwiftUI 状态绑定（光标、选区、修改标记）

**验收**：能打开 ndd 的 9985 行 ccnotepad.cpp，丝滑滚动 + 高亮。

## Phase 2 · 文件 / 编码 (2 周)

**目标**：能用作日常编辑器。

- [ ] 文件打开 / 保存（NSOpenPanel / 拖放）
- [ ] 多标签管理（DocumentManager）
- [ ] 编码检测：移植 ndd `Encode.cpp`，去 Qt 化（用 std::string + 自实现 BOM/启发式）
- [ ] 编码转换：UTF-8 / UTF-16 / GBK / Big5
- [ ] 行尾符识别 / 转换：CRLF / LF / CR
- [ ] 文件变动监控（FSEvents）

**验收**：打开 GBK 中文 .txt 不乱码，存为 UTF-8 正确。

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
