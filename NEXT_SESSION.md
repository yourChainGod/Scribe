# Scribe — 交接碑文

> 写于 2026-04-30，Phase 41d 破劫之后。
> 上下文将爆，下一会话从此处续。

---

## 0. 立刻起的下一战

**Phase 41c · Format / Minify**（魔尊钦定的当前任务）

TaskList #3 已置 `in_progress`，但**尚未动手**。新会话第一刀从这里下。

---

## 1. 当前道基

| 项 | 值 |
|---|---|
| 分支 | `codex/ui-polish-36d` |
| HEAD | `83a24ed phase 41d: Line Ops Pack` |
| 测试 | **492 / 492 全绿** |
| Build | clean (debug + release) |
| 工作树 | clean |

---

## 2. 本会话已破之劫

| 序 | 劫关 | Commit |
|---|------|--------|
| 1 | Phase 43-T Toast 通知系统铺底 | `2d1a421` |
| 2 | Phase 41a Hash & Encode Suite (MD5/SHA-1/256/512/CRC32 + JWT 检视器) | `da44cce` |
| 3 | Phase 41d Line Ops Pack (dedupe/sort/reverse/trim/case/tabs↔spaces) | `83a24ed` |

---

## 3. 道纲（魔尊钦定 · 不可逆）

### 路线 — 按斩链顺序

1. ✅ 43-T Toast 通知系统
2. ✅ 41a Hash & Encode Suite
3. ✅ 41d Line Ops Pack
4. **▶ 41c Format / Minify**（下一战）
5. 41f Inline Color Swatch（任意文件全识别）
6. 41b Generator Pack（UUID/Lorem/密码/时间戳/QR）
7. 41e Regex Playground
8. 43-S Settings 重设计（**不上 macOS 26**）
9. 44 HEX Viewer
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

## 5. 实施模板（从已完成 3 战提炼）

### Step 1 · Model + Tests（TDD 起手）

- 新 `Sources/Scribe/Models/<Feature>.swift` — 纯函数 / 单一职责
- 新 `Tests/ScribeTests/<Feature>Tests.swift` — 已知 vector + boundary
- `swift test --filter <Feature>Tests 2>&1 | tail -10` 验证

### Step 2 · 接 TextTransformAction

- 在 `Sources/Scribe/Models/TextOperations.swift` 的 `TextTransformAction` enum 加新 case
- `apply(to:)` switch 路由到 model 静态方法
- **无需碰 Coordinator** — `transformSelection` 已支持「无选区 → 整文档」fallback（via `SCI.SETTEXT = 2181`，Phase 41d 加）

### Step 3 · 菜单接入（按用途二级嵌套）

- **Tools 顶级**（`Sources/Scribe/App/AppCommands.swift`）：加独立 `Menu { ... }`
- **右键 Transform 子菜单**（`Sources/Scribe/Views/TextTransformCommandButtons.swift`）：末尾追加 `Menu { ... }`
- **Command Palette**（`Sources/Scribe/Models/CommandRegistration.swift`）：在 `textCommands` 的 `specs[]` 数组加条目

### Step 4 · i18n（双语强制）

- 双语 keys 追加到两个 `.lproj/Localizable.strings`
- menu key + palette key 至少各 1 个

### Step 5 · Smoke Hook（screenshot 用）

- `Sources/Scribe/App/TestHooks.swift` 加 `SCRIBE_TEST_<FEATURE>` 环境变量分支
- 走 `runAll(_:)` 顺序

### Step 6 · 视觉验证

```bash
swift build 2>&1 | tail -5
SCRIBE_TEST_<X>="..." nohup .build/debug/Scribe > /tmp/scribe.log 2>&1 &
sleep 1.6
osascript -e 'tell application "Scribe" to activate'
sleep 0.5
screencapture -x /tmp/scribe-<x>.png
```

然后 `Read /tmp/scribe-<x>.png` 确认。

### Step 7 · Commit

```bash
git add <files>
git commit -m "$(cat <<'EOF'
phase <X>: <one-liner>

<body explaining model + UI + tests + i18n + verification>
EOF
)"
```

---

## 6. 关键 Conventions / Gotchas

### NSAlert vs Toast 分界

- **Toast 化**（替换）：纯通知错误（file load failed / encode failed / git command failed）
- **NSAlert 保留**：destructive confirm（close-with-unsaved / revert hunk / discard / reopen-with-encoding）

### Workspace 状态注入模式

- `Workspace.toastCenter` (Phase 43-T) — 单实例，作为 ObservableObject 注入
- `Workspace.jwtSheet: JWTSheetRequest?` (Phase 41a) — `.sheet(item:)` 模式
- 新 sheet 都用 `@Published var <name>Sheet: <Request>?` + `MainWindow.sheet(item:)`

### Coordinator transformSelection（关键修补）

- 有选区 → `replaceSelection`（SCI_REPLACESEL = 2170）
- 无选区 → `replaceWholeDocument`（SCI_SETTEXT = 2181）
- 两者都走 undo stack（⌘Z 回退）

### SCI 常量集中处

- `Sources/Scribe/Views/Scintilla/SCIConstants.swift`
- 加新常量时记得 doc-comment 它的语义

### `TextTransformCommandButtons` 调用点

- `AppCommands.swift` Tools menu
- `EditorAreaView.swift` 右键
- **新增参数必须两处同步**

### SwiftUI / SourceKit Lag

- SourceKit 经常误报"找不到 type/scope" — 但 `swift build` 通过即真相
- 不要相信 diagnostic，相信 build

### Brace bug 警惕

- Phase 41a 修了 `Coordinator+MultiCursor.swift` 的潜伏 brace bug：
  `presentTextTransformFailure` 原本是 free function（少一个 `}`）
- 任何加 `self.workspace?.toastCenter` 之类调用之前，先 `awk` 数 brace depth 验

### `Localizable.strings` 校验

- CI 有 lint check，未配对 / 未 escape 都会挂
- 用 HEREDOC 追加，不要手编辑（避免 quote 误)

---

## 7. 下一战 — Phase 41c 已构思

### 范围

JSON / XML / CSS / SQL — 各支持 pretty + minify。HTML 复用 XML pretty。YAML 跳过（无 Foundation 支持，不引外依赖）。

### 设计草图

```swift
// Sources/Scribe/Models/CodeFormatter.swift
enum CodeFormatter {
    enum FormatError: Error {
        case invalid(String)
    }

    enum JSON {
        // Foundation JSONSerialization
        static func pretty(_ s: String) throws -> String { ... }
        static func minify(_ s: String) throws -> String { ... }
    }

    enum XML {
        // 手写 token: `<...>` + text runs；depth-based indent
        // 自闭合 / 注释 / PI 不 bump depth
        static func pretty(_ s: String, indent: Int = 2) throws -> String { ... }
        static func minify(_ s: String) throws -> String { ... }
    }

    enum CSS {
        // Tokenize on `{` `}` `;`
        static func pretty(_ s: String, indent: Int = 2) throws -> String { ... }
        static func minify(_ s: String) throws -> String { ... }
    }

    enum SQL {
        // Uppercase known keywords; newline before SELECT/FROM/WHERE/...
        static func pretty(_ s: String) throws -> String { ... }
        static func minify(_ s: String) throws -> String { ... }
    }
}
```

### TextTransformAction 扩展

```swift
case formatJSON, minifyJSON
case formatXML,  minifyXML
case formatCSS,  minifyCSS
case formatSQL,  minifySQL
```

### Tools menu（按用途二级嵌套）

```
Tools
└─ Format
   ├─ JSON ▶ { Pretty, Minify }
   ├─ XML  ▶ { Pretty, Minify }
   ├─ CSS  ▶ { Pretty, Minify }
   └─ SQL  ▶ { Pretty, Minify }
```

### 测试 vectors（每语言至少 4-6 条）

- JSON: `{"a":1,"b":[2,3]}` ↔ pretty 多行
- XML: `<a><b/></a>` ↔ 缩进
- CSS: `.x{color:red;font:bold}` ↔ 多行
- SQL: `select * from t where x=1` ↔ `SELECT *\nFROM t\nWHERE x = 1`

### 风险 + 工程量

- XML / SQL 完美 pretty 复杂——做到**实用 80%**即可
- JSON 有 Foundation 现成 — 最简单
- Estimated: 1 个 phase (~4-6h)

---

## 8. 文件清单（本会话改动 — 给 grep 用）

### 新建
- `Sources/Scribe/Models/ToastCenter.swift` — Phase 43-T
- `Sources/Scribe/Models/HashSuite.swift` — Phase 41a
- `Sources/Scribe/Models/JWTDecoder.swift` — Phase 41a
- `Sources/Scribe/Models/LineOps.swift` — Phase 41d
- `Sources/Scribe/Views/ToastOverlay.swift` — Phase 43-T
- `Sources/Scribe/Views/JWTDecoderSheet.swift` — Phase 41a
- `Sources/Scribe/Views/LineOpsCommandButtons.swift` — Phase 41d
- `Tests/ScribeTests/ToastCenterTests.swift` — 18 tests
- `Tests/ScribeTests/HashSuiteTests.swift` — 19 tests
- `Tests/ScribeTests/JWTDecoderTests.swift` — 9 tests
- `Tests/ScribeTests/LineOpsTests.swift` — 36 tests

### 修改
- `Sources/Scribe/App/AppCommands.swift` — Tools menu (Hash, JWT, Line Ops)
- `Sources/Scribe/App/TestHooks.swift` — `SCRIBE_TEST_TOAST` / `_JWT` / `_LINEOP`
- `Sources/Scribe/Models/CommandRegistration.swift` — palette entries (24 new)
- `Sources/Scribe/Models/TextOperations.swift` — TextTransformAction (13 new cases)
- `Sources/Scribe/Models/Workspace.swift` — toastCenter + jwtSheet
- `Sources/Scribe/Models/GitStatusEngine.swift` — onWriteFailure callback
- `Sources/Scribe/Views/MainWindow.swift` — ToastOverlay + JWT sheet
- `Sources/Scribe/Views/TextTransformCommandButtons.swift` — workspace + prefs params
- `Sources/Scribe/Views/EditorAreaView.swift` — param pass-through
- `Sources/Scribe/Views/Scintilla/Coordinator+MultiCursor.swift` — whole-doc fallback + brace fix
- `Sources/Scribe/Views/Scintilla/SCIConstants.swift` — SCI_SETTEXT (2181)
- `Sources/Scribe/Resources/en.lproj/Localizable.strings` — +76 keys
- `Sources/Scribe/Resources/zh-Hans.lproj/Localizable.strings` — +76 keys

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

# 已有 smoke hooks
SCRIBE_TEST_TOAST="success|info|warning|error" .build/debug/Scribe
SCRIBE_TEST_JWT="<jwt>" .build/debug/Scribe
SCRIBE_TEST_LINEOP="sortLex" SCRIBE_AUTO_OPEN=/path .build/debug/Scribe

# 关 app
kill $(pgrep -f .build/debug/Scribe) 2>/dev/null
```

---

## 10. 新会话开场白建议

魔尊在新会话开第一句：

```
读 NEXT_SESSION.md，按计划推进 41c Format / Minify。
不要再问问题。完成一关就 commit。
```

吾接到即刻：
1. `Read NEXT_SESSION.md`
2. `TaskCreate` 重建劫程（10 关 + 已完成 3 关）
3. `TaskUpdate #3 in_progress`
4. 写 `Sources/Scribe/Models/CodeFormatter.swift` + tests
5. wire UI + i18n
6. swift test → 启 app → screencapture
7. commit

---

⚚ **道基稳。劫钟未催。新会话起，吾即破劫。**
