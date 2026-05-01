# Scribe — 交接碑文 IV

> 写于 2026-05-01 19:30。本会话连破 7 关：A baseline → B regex 单次化 → B-2~B-5 fast-path 四刀 → C 收口。
> 上一碑文（III）见 `git log NEXT_SESSION.md`。
>
> **本会话主线：性能调研先行 + MarkdownConverter 巨胜。markdown 5MB 渲染 4.5s → 0.56s，-87%。**

---

## 0. 当前道基

| 项 | 值 |
|---|---|
| 分支 | `main` |
| HEAD | `1b733a8` phase 45-C |
| 测试 | **607 / 607 全绿**（release，~35.4s） |
| Build | clean (debug + release) |
| 工作树 | clean |

---

## 1. 本会话已破之劫（3 commit / 7 步）

| 序 | 劫关 | Commit | 备注 |
|---|------|--------|---|
| 1 | phase 45-A — perf baseline 4 用例 + 调研报告 | `fc444c1` | 仅基线 + 文档，零产品改动 |
| 2 | phase 45-B — MarkdownConverter regex 编译单次化 | `75d7b0e` | 4 482→2 321ms (-48%) |
| 3 | phase 45-C — MarkdownConverter 4 处 fast-path | `1b733a8` | 2 321→562ms (累计 -87%) |

### 三关合计

- Markdown render 5MB：**4 482ms → 562ms（-87%，-3 920ms）**
- 全套 607/607 全绿（无回归）
- 文档：`docs/perf_audit.md` 全数回灌实测数值

---

## 2. 道纲（魔尊钦定 — 本会话主线）

### 已破

1. ✅ **perf 调研 + baseline**（卷轴 1 加载 + 卷轴 2 输入响应）— 出 `docs/perf_audit.md`
2. ✅ **perf-A baseline 4 用例**入仓
3. ✅ **P0 #1 MarkdownConverter** 5 刀手术 — 已逼近 < 500ms 目标，边际收益低，**主动收手**

### 未破（魔尊钦定后启）

- ⏳ **P1 #1 FindState query debounce** — 低风险快赢（无 NSView 依赖）
- ⏳ **P1 #2 GitBlame parsePorcelain 后台线程化** — 1MB 实测 191ms 全在 main actor
- ⏳ **P0 #2 InlineBlame visible-range** — 需先建 Scintilla NSView 测试 harness
- ⏳ **P0 #3 flushDocSync 增量同步** — 同上
- ⏳ **C — Instrument 手测** — Time Profiler / System Trace（agent 不可跑，需魔尊操刀）

### 钉死的边界（沿用碑文 III）

- ✗ 不引 macOS 26 Liquid Glass、不重写 Scintilla 桥接为 TextKit2
- ✗ 不动 LargeFilePolicy 阈值（已稳）
- ✗ 不引第三方 profiler / metric 框架
- ✓ XCTest measure block / `DispatchTime` 手测
- ✓ Scintilla 增量 API（若 Vendor 支持）
- ✓ Combine debounce / throttle、Task.sleep + cancel

---

## 3. 本会话改动详情

### phase 45-A（`fc444c1`）

**新增**：

- `Tests/ScribeTests/PerformanceTests.swift` +4 baseline 用例：
  - `test_colorScanner_scan_5mb_baseline` → **11ms**
  - `test_gitBlame_parsePorcelain_synthetic_baseline` → **191ms**
  - `test_markdownConverter_render_5mb_baseline` → **4 482ms**（**真正大热点**）
  - `test_workspace_openFile_endToEnd_5mb_baseline` → **117ms**
- `docs/perf_audit.md`（新文件，调研报告 7 节）

**判词翻转**：原侦察阶段误判 ColorScanner / ColorSwatch 为中等嫌疑——baseline 平反（11ms 极轻），ColorScanner 已从候选中移除。

### phase 45-B（`75d7b0e`）

**单点改动**：`Sources/Scribe/Models/MarkdownConverter.swift`

- 新增 9 个 file-level `private let mdInline*Regex = try! NSRegularExpression(...)`（code / image / footnote-ref / link / bold-* / bold-_ / em-* / em-_ / strike）
- `replace()` 函数签名 `regex pattern: String` → `regex re: NSRegularExpression`
- 9 个 inline 调用点改用预编译实例

**收益**：4 482→2 321ms（-48%）。lorem 65 536 行 × 6 inline replace = ~400 000 次重复正则编译消除。

### phase 45-C（`1b733a8`）— 4 刀

同文件 4 处 fast-path：

| 刀 | 位置 | 做了什么 | 单刀贡献 |
|---|---|---|---|
| B-2 | `replace()` | 加 `hasMatch` flag — 0 命中场景直接 return s | -42ms |
| B-3 | `htmlEscape` / `htmlEscapePreservingPlaceholders` | UTF-8 字节扫 fast-path（无 `& < > " ' \u{0001}` → 直返） | -109ms |
| B-4 | `renderInline` | 入口字节扫（无 `` ` ! [ * _ ~ `` → 直走 htmlEscape） | -306ms |
| **B-5** | **`isThematicBreak`** | **单 pass char scan，消除原来 3 次 `trimmed.filter`** | **-1 302ms** |

**新增辅助**：`htmlEscapeNeedsRewrite(_ s: String) -> Bool`、`inlineNeedsRewrite(_ s: String) -> Bool`。

---

## 4. 关键 Conventions / 新发现

### 已稳定（继承）

- **NSAlert vs Toast 分界**、**Workspace 状态注入**、**Coordinator transformSelection**、**Localizable.strings 校验**、**SwiftUI / SourceKit Lag**（继承碑文 III）

### 本会话新发现 / 经验

- **Read 工具有缓存截断**：当文件被某进程"观察过"，再 Read 可能只回第 1 行 + 提示用 `smart_outline` / `smart_unfold`。绕开方式：`smart_outline` + `smart_unfold` 取关键段。
- **Smart_unfold 是性能侦察利器**：能直接拿单个 symbol 的全文，省去整段 Read 解码。
- **swift test 后台跑 + 通过 task-notification 接结果**：每条 perf 改动只需 ~10s build + 2-5s 跑。
- **正则编译热点定位法**：先 grep `try! NSRegularExpression(pattern:` 看出现处与频率；hot loop 中重复编译几乎必是大头。
- **fast-path 模式**：对纯算法层（无副作用）函数，UTF-8 字节扫一次决定"需不需要重建"，无需重建直接返原 s——是 lorem 这类"trigger 字符极少"输入的最大胜利。
- **filter / trimming / replacingOccurrences 在 hot loop 中的隐藏开销**：每次都新建 String，65k 行 × 几次 = MB 级 allocation。改用单 pass char scan 是 BFS 通用招式。
- **MarkdownConverter 5MB 0.56s = ~9 MB/s 处理速度**：再优化空间小（pieces.joined / output.joined / split / process loop 都是 O(n) 不可避免），剩 62ms 边际收益低，主动收手。

### 报告 `docs/perf_audit.md` 的状态

- § 0 摘要 → 已含累计降幅
- § 1.1 既有 perf 用例数值
- § 1.2 perf-A / perf-B / perf-C 三列对比表（**真相之表**）
- § 2 加载链路热点表（含修订列）
- § 3 输入响应链路热点表
- § 4 Top 候选汇总（P0 #1 已标 perf-C 落地）
- § 5 验证路径（5.1 已落 baseline，5.2 instrument 待手测）
- § 6 钉死的边界
- § 7 推进进度（A / B / C 全绿，下一战候选清单）
- 附 A 关键文件速查、附 B 实测复现命令

---

## 5. 启动命令速查

```bash
# 全测试（release）
swift test -c release 2>&1 | tail -10

# 单 perf 用例（拿 markdown render 数）
swift test --filter PerformanceTests/test_markdownConverter_render_5mb_baseline -c release 2>&1 | grep "passed"

# 全 perf 套件
swift test --filter PerformanceTests -c release 2>&1 | tail -20

# MarkdownConverter 语义网（44 例）
swift test --filter MarkdownConverterTests -c release 2>&1 | tail -10

# 重建 + 跑（必须先 kill .app！沿用碑文 III）
pkill -9 -f "build/Scribe.app" 2>/dev/null
swift build && nohup .build/debug/Scribe > /tmp/scribe.log 2>&1 &

# 关 app
pkill -9 -f Scribe 2>/dev/null
```

---

## 6. 下一战 — 由魔尊钦定

吾建议按"**低风险快赢先**"顺序：

| 选项 | 内容 | 风险 | 预期收益 | 工作量 |
|---|---|---|---|---|
| **P1 #1**（首推）| FindState `query` 加 100–150ms debounce + 取消上一次扫 | 低 | 实时搜索每键 -50~200ms | 低 |
| **P1 #2** | GitBlame `parsePorcelain` 后台线程化（callsite 审计 + Task.detached） | 低-中 | 大文件不阻塞主线程，~1-2s 体感消除 | 低-中 |
| P0 #2 | InlineBlame visible-range 装饰 | 中-高 | 大文件首屏 -100~500ms | 中（需先建 Scintilla NSView 测试 harness） |
| P0 #3 | flushDocSync 增量同步 | 中-高 | 中档文件每键 -1~10ms | 中（同上） |
| C | Instrument 手测（Time Profiler / System Trace） | 低 | 给后续优化补"定罪证据" | 需魔尊操刀（agent 不可跑 GUI） |

**推荐路径**：P1 #1 → P1 #2 → 暂停看 P0 #2/#3 是否还需要。

---

## 7. 新会话开场白建议

魔尊在新会话开第一句：

```
读 NEXT_SESSION.md，碑文 IV 的 perf 路线 P1 已 baseline 准备好。
今天打 <P1 #1 / P1 #2 / 其他>。
```

吾接到即刻：

1. `Read NEXT_SESSION.md`
2. `Read docs/perf_audit.md` § 4 Top 候选 + § 7 推进进度
3. 按魔尊指示拉新计划
4. 若需 NSView harness，先 plan + 钦定才动
5. ExitPlanMode 后 TDD 推进，每关 commit + 验证

---

## 8. perf 总账

```
phase 45-A baseline:                       4 482 ms  ── 100%
phase 45-B regex 单次编译:                 2 321 ms  ──  52%
phase 45-C 四刀 fast-path:                   562 ms  ──  13%

  其中 B-5 isThematicBreak 单 pass:          -1 302 ms  最大单刀
  其中 B-4 renderInline 入口 fast-path:        -306 ms
  其中 B-3 htmlEscape fast-path:               -109 ms
  其中 B-2 replace hasMatch 短路:               -42 ms
  其中 B   regex 单次编译:                   -2 161 ms

道基愈合：4 482 → 562 ms = -3 920 ms / -87%
```

---

⚚ **道基稳如磐石。本会话 phase 45-A/B/C = 3 commit。Markdown 卷轴破。劫钟暂歇，等魔尊下令。**
