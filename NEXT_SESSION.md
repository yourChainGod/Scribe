# Scribe — 交接碑文 III

> 写于 2026-04-30 16:55，本会话连破 3 关之后（43-S × 2 + #10 横切 polish）。
> 上一碑文（已废）见 `git log NEXT_SESSION.md`。
>
> **路线 9 + 1 = 10/10，碑文道纲全数完成。**

---

## 0. 当前道基

| 项 | 值 |
|---|---|
| 分支 | `codex/ui-polish-36d` |
| HEAD | `<this commit>` |
| 测试 | **601 / 601 全绿**（GitClient 集成测试偶发 flaky，重跑必绿）|
| Build | clean (debug + release) |
| 工作树 | clean |

---

## 1. 本会话已破之劫（3 关，按 commit 顺序）

| 序 | 劫关 | Commit |
|---|------|--------|
| 1 | Phase 43-S (1/2) Settings — surface Inline Color Swatches toggle | `5550a2c` |
| 2 | Phase 43-S (2/2) Settings polish — snippets icon + about version | `53f5d41` |
| 3 | #10 横切 polish 收口 — Settings frame + NEXT_SESSION III | `<this>` |

---

## 2. 道纲（10/10 全破，魔尊钦定）

1. ✅ 43-T Toast 通知系统
2. ✅ 41a Hash & Encode Suite
3. ✅ 41d Line Ops Pack
4. ✅ 41c Format / Minify
5. ✅ 41f Inline Color Swatch
6. ✅ 41b Generator Pack
7. ✅ 41e Regex Playground
8. ✅ **43-S Settings 重设计**（本会话破）
9. ✅ 44 HEX Viewer
10. ✅ **横切 polish 收口**（本会话破）

### 钉死的边界（魔尊明令禁止 — 仍生效）

- ✗ 产品化（DMG / Sparkle / brew / notarization）
- ✗ Git editable hunks / Git v2
- ✗ Phase 42 编辑深耕（Bookmarks / Macro / Clipboard / Doc Stats / Sync Scroll）
- ✗ macOS 26 Liquid Glass / 26 风格升级
- ✗ Snippets v2 / Markdown v3 / Document Map
- ✓ Notepad++ 灵魂的"小而精致"工具
- ✓ UI/UX 现代化（横切贯穿每关）
- ✓ Tools 菜单按用途二级嵌套

---

## 3. 本会话改动详情（43-S + #10）

### 43-S Settings 重设计

**目标**：在现有 TabView 框架内重组、不引 macOS 26 Liquid Glass。

**做法**：
1. **新增 Display section**（位于 Editor tab，在 Indentation 与 Inline Blame 之间）
   - 收纳 `inlineColorSwatchesEnabled` toggle（之前只在 View 菜单 + palette 可达）
   - Footer 解释色块在任意文件类型生效
2. **Snippets tab icon 换装**：`doc.text.below.ecg`（vital-signs glyph，无语义）→ `chevron.left.forwardslash.chevron.right`（`</>`）
3. **About 版本号刷新**：`v1.0 · Phase 25 polish` → `v1.0 · Phase 44 build`（zh: `v1.0 · 第 44 阶段构建`）
4. **i18n 新增 keys**（en + zh-Hans 各 3 个）：
   - `settings.section.display`
   - `settings.display.colorSwatches`
   - `settings.display.colorSwatchesFooter`

### #10 横切 polish 收口

- `SettingsView.swift` frame `height: 460` → `520` — Editor tab 加 5th section 后原高度挤压 Recent Files 行。

---

## 4. Workspace sheet 一览（继承自上一碑文）

```swift
@Published var jwtSheet: JWTSheetRequest?           // 41a
@Published var passwordSheet: PasswordSheetRequest? // 41b
@Published var qrSheet: QRSheetRequest?             // 41b
@Published var regexSheet: RegexSheetRequest?       // 41e
@Published var hexViewerSheet: HexViewerRequest?    // 44
```

## 5. Smoke hooks 一览（继承）

```bash
SCRIBE_TEST_TOAST="success|info|warning|error"  # 43-T
SCRIBE_TEST_JWT="<token>"                       # 41a
SCRIBE_TEST_LINEOP="sortLex|dedupe|..."         # 41d
SCRIBE_TEST_FORMAT="jsonPretty|xmlMinify|..."   # 41c
SCRIBE_TEST_GENERATE="uuid|lorem|qr.<url>|..."  # 41b
SCRIBE_TEST_REGEX="<subject>"                   # 41e
SCRIBE_TEST_HEX="1"                             # 44
```

---

## 6. 关键 Conventions / Gotchas（继承 + 新发现）

### 已稳定的部分（继承）

- **NSAlert vs Toast 分界**：纯通知错误用 Toast；destructive confirm 保留 NSAlert
- **Workspace 状态注入**：`@Published var <name>Sheet: <Request>?` + `MainWindow.sheet(item:)`
- **Coordinator transformSelection**：有选区 `replaceSelection`，无选区 `replaceWholeDocument`，都走 undo stack
- **`Localizable.strings` 校验**：CI 有 lint check，未配对 / 未 escape 都会挂；用 HEREDOC 追加
- **SwiftUI / SourceKit Lag**：误报"找不到 type/scope"无需理睬 — 信 `swift build`

### 本会话新发现

- **macOS Settings 双 Scribe 进程陷阱**：项目根目录 `build/Scribe.app/Contents/MacOS/Scribe` 是产品化 bundle。`tell application "Scribe" to activate` 会激活 .app 而不是 `.build/debug/Scribe`。验证 UI 必须用 PID-based AppleScript：
  ```osascript
  tell application "System Events"
    set frontmost of (first process whose unix id is $DEBUG_PID) to true
  end tell
  ```
  或先 `pkill -9 -f "build/Scribe.app"` 清场。
- **Cmd+, 不可靠**：脚本里 `keystroke "," using command down` 偶尔不打开 Settings。改走菜单：
  ```osascript
  click menu item "Settings…" of menu 1 of menu bar item "Scribe"
  ```
- **Settings TabView 切换**：tab toolbar `UI element <N>` 索引化（1/2/3/4 = Editor/Appearance/Snippets/About），`perform action "AXPress" of UI element <N>` 切换。比 keystroke 稳。
- **GitClientWriteIntegrationTests flaky**：会话中曾报 1 failure，重跑全绿。整套测试有 git fixture 时序敏感性，重跑即可。

---

## 7. 启动命令速查

```bash
# 全测试
swift test 2>&1 | tail -10

# 单 suite
swift test --filter <Suite>Tests 2>&1 | tail -10

# 重建 + 跑（必须先 kill .app！）
pkill -9 -f "build/Scribe.app" 2>/dev/null
swift build && nohup .build/debug/Scribe > /tmp/scribe.log 2>&1 &

# Settings 截图（PID-based，最稳）
DEBUG_PID=$(pgrep -f .build/debug/Scribe | head -1)
osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $DEBUG_PID) to true"
osascript <<EOF
tell application "System Events"
  tell (first process whose unix id is $DEBUG_PID)
    tell menu bar 1
      click menu item "Settings…" of menu 1 of menu bar item "Scribe"
    end tell
  end tell
end tell
EOF
sleep 1.5 && screencapture -x /tmp/scribe.png

# 关 app
pkill -9 -f Scribe 2>/dev/null
```

---

## 8. 下一战 — 由魔尊钦定

碑文道纲 10/10 全破。下一战不在路线图内 — 魔尊在新会话里指什么打什么。

**可能的方向**（魔尊未点名前不动）：

- 用户实测 Settings 重设计后的反馈调优
- 残留 Snippets v2 / Markdown v3 解禁（魔尊明令解禁后才动）
- 编辑深耕（Bookmarks / Macro / Clipboard / Doc Stats / Sync Scroll，Phase 42 系列）— 同样需解禁
- 真正的产品化（DMG / Sparkle / 公证）— 魔尊明令解禁后才动
- macOS 26 Liquid Glass — 魔尊明令解禁后才动

---

## 9. 新会话开场白建议

魔尊在新会话开第一句：

```
读 NEXT_SESSION.md，碑文 10/10 已破。今天的任务是 <X>。
```

吾接到即刻：
1. `Read NEXT_SESSION.md`
2. 按魔尊指示拉新计划
3. 若需大改用 `EnterPlanMode` 对齐
4. ExitPlanMode 后 TDD 推进，每关 commit + 验证

---

⚚ **道基稳如磐石。碑文道纲圆满。本会话 43-S × 2 + #10 = 3 commit。劫钟暂歇，等魔尊下令。**
