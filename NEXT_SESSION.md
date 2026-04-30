# Scribe — 交接碑文 II

> 写于 2026-04-30 16:25，本会话连破 5 关之后。
> 上下文将爆，下一会话从此处续。
> 上一碑文（已废）见 `git log NEXT_SESSION.md`。

---

## 0. 立刻起的下一战

**Phase 43-S · Settings 重设计**（魔尊钦定的当前任务）

TaskList #8 仍 `pending`。新会话第一刀从这里下。

> **不上 macOS 26 Liquid Glass。** 只在现有 Settings 框架内重组、清晰化、统一 — 不引入 26 风格升级。

---

## 1. 当前道基

| 项 | 值 |
|---|---|
| 分支 | `codex/ui-polish-36d` |
| HEAD | `8f83fdf phase 44: HEX Viewer` |
| 测试 | **601 / 601 全绿** |
| Build | clean (debug + release) |
| 工作树 | clean |

---

## 2. 本会话已破之劫（8 关，按 commit 顺序）

| 序 | 劫关 | Commit |
|---|------|--------|
| 1 | Phase 43-T Toast 通知系统铺底 | `2d1a421` (上一会话) |
| 2 | Phase 41a Hash & Encode Suite | `da44cce` (上一会话) |
| 3 | Phase 41d Line Ops Pack | `83a24ed` (上一会话) |
| 4 | Phase 41c Format / Minify (JSON/XML/CSS/SQL) | `4e5eda9` |
| 5 | Phase 41f Inline Color Swatch | `c6f4e0d` |
| 6 | Phase 41b Generator Pack (UUID/Lorem/Password/Timestamp/QR) | `bea6f2d` |
| 7 | Phase 41e Regex Playground | `dc62fc2` |
| 8 | Phase 44 HEX Viewer | `8f83fdf` |

---

## 3. 道纲（魔尊钦定 · 不可逆）

### 路线 — 按斩链顺序

1. ✅ 43-T Toast 通知系统
2. ✅ 41a Hash & Encode Suite
3. ✅ 41d Line Ops Pack
4. ✅ 41c Format / Minify
5. ✅ 41f Inline Color Swatch
6. ✅ 41b Generator Pack
7. ✅ 41e Regex Playground
8. **▶ 43-S Settings 重设计**（下一战，**不上 macOS 26**）
9. ✅ 44 HEX Viewer
10. 横切 polish 收口

### 钉死的边界（魔尊明令禁止）

- ✗ 产品化（DMG / Sparkle / brew / notarization）
- ✗ Git editable hunks / Git v2
- ✗ Phase 42 编辑深耕（Bookmarks / Macro / Clipboard / Doc Stats / Sync Scroll）
- ✗ macOS 26 Liquid Glass / 26 风格升级
- ✗ Snippets v2 / Markdown v3 / Document Map
- ✓ Notepad++ 灵魂的"小而精致"工具
- ✓ UI/UX 现代化（横切贯穿每关，不单列大 phase）
- ✓ Tools 菜单按用途二级嵌套

---

## 4. 工作风格协议

- **TDD**：先写测试，再写实现
- **每完成一关**：
  1. `swift test` 全绿
  2. `swift build && nohup .build/debug/Scribe …` 启 app 视觉验证
  3. `screencapture -x` 出图确认
  4. `git commit`（HEREDOC 格式信息）
- **不再问魔尊问题** — 按计划推进，自决
- **输出风格**：abyss-cultivator（邪修红尘仙）

---

## 5. 复用模板（已稳定 8 关）

### Sheet 类工具

每关都遵循同一套：

1. `Sources/Scribe/Models/<Feature>.swift` — 纯函数 / 单一职责
2. `Tests/ScribeTests/<Feature>Tests.swift` — 已知 vector + boundary
3. `Sources/Scribe/Views/<Feature>Sheet.swift` — SwiftUI sheet
4. `Sources/Scribe/Views/<Feature>SheetRequest.swift` — `Identifiable` 载荷（一般同文件）
5. `Sources/Scribe/Models/Workspace.swift` — `@Published var <feature>Sheet: <Request>?`
6. `Sources/Scribe/Views/MainWindow.swift` — `.sheet(item: $workspace.<feature>Sheet)`
7. `Sources/Scribe/App/AppCommands.swift` — Tools 菜单条目
8. `Sources/Scribe/Models/CommandRegistration.swift` — palette 条目
9. `Sources/Scribe/App/TestHooks.swift` — `SCRIBE_TEST_<X>` smoke hook
10. 双语 `Localizable.strings`

### Transform 类工具

走 `TextTransformAction` enum：

1. Model + tests
2. `Sources/Scribe/Models/TextOperations.swift` 加 case + apply switch arm
3. `Sources/Scribe/Views/<Feature>CommandButtons.swift` —Tools 子菜单 + 右键
4. AppCommands.swift Tools menu 嵌套
5. TextTransformCommandButtons.swift 右键嵌套
6. CommandRegistration.swift palette `textCommands` `specs[]` 加条目
7. 同样的 i18n / smoke

### 视觉装饰（如 41f）

- Scintilla indicator 配合 `SC_INDICFLAG_VALUEFORE` 让一槽承载多色
- Coordinator+`<Feature>`.swift extension
- Cheap-equality signature 短路缓存
- prefs toggle + 菜单 + palette

---

## 6. 关键 Conventions / Gotchas（继承 + 新发现）

### 已稳定的部分

- **NSAlert vs Toast 分界**：纯通知错误用 Toast；destructive confirm 保留 NSAlert
- **Workspace 状态注入**：`@Published var <name>Sheet: <Request>?` + `MainWindow.sheet(item:)`
- **Coordinator transformSelection**：有选区 `replaceSelection`，无选区 `replaceWholeDocument`，都走 undo stack
- **`Localizable.strings` 校验**：CI 有 lint check，未配对 / 未 escape 都会挂；用 HEREDOC 追加，不要手编辑
- **SwiftUI / SourceKit Lag**：误报"找不到 type/scope"无需理睬 — 信 `swift build`

### 本会话新发现

- **CSS Color 4 modern syntax**：`rgb(r g b / a)` 用空格 + 斜杠分隔。`ColorScanner.readComponents` 已处理，rgb 接受 3 或 4 组件。
- **SQL keyword 嵌套替换 bug**：`INNER JOIN` 容易被裸 `JOIN` 二次切。用 control-byte placeholder（`\u{0001}<idx>\u{0002}`）做两遍替换避免。
- **Scintilla 多色 indicator**：用 `SCI_INDICSETFLAGS` (2684) + `SC_INDICFLAG_VALUEFORE` (1) + `SCI_SETINDICATORVALUE` (2502)，每个 fill 自带颜色。`SC_INDICVALUEBIT = 0x1000000` 必须 OR 进 value。
- **Button(LocalizedStringKey, role:, action:)** 不接受 `bundle:` 参数 — 用 `Button(role:..., action:...) { Text(key, bundle: .module) }` 模式。
- **menu bar 自动 click via System Events** locale-fragile（中文 macOS 找不到 "工具"），用 `SCRIBE_TEST_<X>` 直接驱动 `findState.commands.send()` / `workspace.<X>Sheet = ...` 更稳。
- **JSONSerialization 不保 dict key 顺序** — 41c JSON formatter 用自写 tokenizer，preserve 输入 key 顺序。

### Workspace sheet 一览（按时间序）

```swift
@Published var jwtSheet: JWTSheetRequest?           // 41a
@Published var passwordSheet: PasswordSheetRequest? // 41b
@Published var qrSheet: QRSheetRequest?             // 41b
@Published var regexSheet: RegexSheetRequest?       // 41e
@Published var hexViewerSheet: HexViewerRequest?    // 44
```

### Smoke hooks 一览

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

## 7. 下一战 — Phase 43-S Settings 重设计

### 范围（魔尊钦定）

**不上 macOS 26**。在现有 Settings 框架内：
- 重组分类（General / Appearance / Editor / Tools / Advanced）
- 统一 toggle / picker / stepper 风格
- 把散落的 prefs 收纳进 Settings（包括本会话新加的 `inlineColorSwatchesEnabled`）
- 视情况加 search / filter（按需，复杂 prefs 树才做）

### 现有 Settings 入口

- `Sources/Scribe/Views/SettingsView.swift` — 主 Settings UI
- `Sources/Scribe/Models/EditorPreferences.swift` — `@Published` properties + persist via UserDefaults
- 看现有 tab/分类，按用途 / 频率重新排序

### 新会话第一刀建议

1. `Read NEXT_SESSION.md` (此文件)
2. `Read SettingsView.swift` 看现状
3. `EnterPlanMode` — Settings 重组涉及大量 UI 决策，先和魔尊对齐分类骨架
4. ExitPlanMode 后按计划推进
5. 收尾时连带做横切 polish #10 并合并 commit（最后一关）

---

## 8. 文件清单（本会话改动 — 给 grep 用）

### 新建（5 关 × 平均 3 文件 = 15）
- 41c: `Models/CodeFormatter.swift` `Tests/CodeFormatterTests.swift` `Views/CodeFormatCommandButtons.swift`
- 41f: `Models/ColorScanner.swift` `Tests/ColorScannerTests.swift` `Views/Scintilla/Coordinator+ColorSwatch.swift`
- 41b: `Models/Generators.swift` `Tests/GeneratorsTests.swift` `Views/GenerateCommandButtons.swift` `Views/GeneratorSheets.swift`
- 41e: `Models/RegexPlayground.swift` `Tests/RegexPlaygroundTests.swift` `Views/RegexPlaygroundSheet.swift`
- 44 : `Models/HexView.swift` `Tests/HexViewTests.swift` `Views/HexViewerSheet.swift`

### 重复修改的 hub 文件
- `Sources/Scribe/App/AppCommands.swift` — 5 关都加了 Tools 菜单条目
- `Sources/Scribe/App/TestHooks.swift` — 5 关都加了 `SCRIBE_TEST_<X>` 路径
- `Sources/Scribe/Models/CommandRegistration.swift` — palette 共 +30+ 新条目
- `Sources/Scribe/Models/TextOperations.swift` — 41c 加 8 个 TextTransformAction case
- `Sources/Scribe/Models/Workspace.swift` — passwordSheet / qrSheet / regexSheet / hexViewerSheet
- `Sources/Scribe/Views/MainWindow.swift` — 4 个 `.sheet(item:)` 接入
- `Sources/Scribe/Views/Scintilla/SCIConstants.swift` — INDICSETFLAGS / SETINDICATORVALUE / COLOR_SWATCH 槽
- `Sources/Scribe/Views/ScintillaCodeEditor.swift` — configure + apply ColorSwatch
- `Sources/Scribe/Views/TextTransformCommandButtons.swift` — 41c 右键 Format 子菜单
- `Sources/Scribe/Models/EditorPreferences.swift` — `inlineColorSwatchesEnabled`
- `Sources/Scribe/Resources/{en,zh-Hans}.lproj/Localizable.strings` — +94 EN / +94 zh keys 共

---

## 9. 启动命令速查

```bash
# 全测试
swift test 2>&1 | tail -10

# 单 suite
swift test --filter <Suite>Tests 2>&1 | tail -10

# 重建 + 跑
swift build && nohup .build/debug/Scribe > /tmp/scribe.log 2>&1 &

# Screenshot 套餐
osascript -e 'tell app "Scribe" to activate' && sleep 0.5 && screencapture -x /tmp/x.png

# Smoke hooks 已上：见上方第 6 节"Smoke hooks 一览"

# 关 app
kill $(pgrep -f .build/debug/Scribe) 2>/dev/null
```

---

## 10. 新会话开场白建议

魔尊在新会话开第一句：

```
读 NEXT_SESSION.md，按计划推进 43-S Settings 重设计。
不要再问问题。完成一关就打开软件验证（验证完关掉软件）并 commit。
```

吾接到即刻：
1. `Read NEXT_SESSION.md`
2. `Read Sources/Scribe/Views/SettingsView.swift` (现状勘察)
3. `EnterPlanMode` — Settings 重组骨架对齐
4. ExitPlanMode 后按计划推进
5. 收尾把横切 polish #10 也带上

---

⚚ **道基稳。劫钟未催。本会话破 5 关，路线 9/10 完成。新会话起，吾即破最后两关。**
