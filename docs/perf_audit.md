# Scribe 性能调研报告

> 写于 2026-05-01。卷轴 1（加载卡顿）+ 卷轴 2（输入响应）专项调研，仅含证据与候选，**不含已落地补丁**。

---

## 0. 摘要

| 项 | 现状 |
|---|---|
| 同步开仓预算（openFile sync 部分） | **已达标**，1MB / 5MB / 20MB 实测 0–3ms（< 50ms 预算） |
| Find-in-files 20MB 扫描 | 114ms，单次完成 |
| 端到端开 5MB（含 decode + applyLoadResult） | **117ms**（perf-A 实测） |
| ColorScanner.scan 5MB | **11ms**（perf-A 实测，原以为重点，实际极轻） |
| MarkdownConverter.render 5MB | **4 482ms → 562ms**（perf-A → perf-C，**-87%**；regex 单次编译 + 4 处 fast-path） |
| GitClient.parseBlamePorcelain ~7 700 行 / ~1MB | **191ms**（perf-A 实测） |
| 嫌疑热点（综合两路侦察 + perf-A 实测修订） | 4 处明确，1 处需进一步 profile |

**结论**（perf-A baseline 后修订）：

- 同步路径已经轻量化得很到位。
- **真正的体感卡顿排序已修订**：
  1. **MarkdownConverter.render** — 5MB 单次 4.5s，是迄今实测的最重单点；只要 markdown preview 开着，每次 markdown 文本变化都要全量重渲。
  2. **GitBlame parsePorcelain** — 1MB 输入 191ms，按线性外推 5MB ≈ 1s，10MB ≈ 2s，全程 main actor。
  3. **InlineBlame applyAllInlineBlames** — 仍是怀疑（无独立基线，依赖 Scintilla NSView，需手测 profile）。
  4. **flushDocSync 全文复制** — 仍是怀疑（中档文件 50ms 一次）。
- **判词翻转**：原以为 ColorScanner 是中等嫌疑，实测 5MB 仅 11ms — **已平反，移出候选**。
- Find bar 的 query 无 debounce 仍是输入响应路径的隐藏抖动点（无独立基线，定性确认）。

---

## 1. 现状实测（release 构建）

来源：`Tests/ScribeTests/PerformanceTests.swift`（**8 例**，全部 release 模式）。

### 1.1 既有用例（同步预算）

| 用例 | 实测 | 预算 | 备注 |
|---|---|---|---|
| `test_openFile_1mb_under_50ms` | 0.002s | 50ms | 同步段：占位 doc + isLoading + stat |
| `test_openFile_5mb_under_50ms` | 0.001s | 50ms | 同上 |
| `test_openFile_20mb_under_50ms` | 0.002s | 50ms | 同上 |
| `test_findInFiles_20mb_scanCompletes` | 0.112s | 完成性 | 走 detached Task，不阻塞主线程 |

### 1.2 perf-A baseline + perf-B / perf-C 落地后

| 用例 | perf-A 基线 | perf-B 后 | **perf-C 后** | 累计变化 |
|---|---|---|---|---|
| `test_colorScanner_scan_5mb_baseline` | 11ms | — | — | unchanged |
| `test_gitBlame_parsePorcelain_synthetic_baseline` | 191ms | — | — | unchanged |
| `test_markdownConverter_render_5mb_baseline` | **4 482ms** | 2 321ms | **562ms** | **-87% (-3 920ms)** |
| `test_workspace_openFile_endToEnd_5mb_baseline` | 117ms | 111ms | ≈111ms | noise |

> perf-A baseline 入仓 2026-05-01 17:51；perf-B 入仓 18:13；**perf-C 入仓 19:30**。
>
> **perf-B 单刀**：`MarkdownConverter.swift` 把 `replace()` 内的 `try! NSRegularExpression(pattern:)` 由"每次调用编译"改为 9 个 file-level `private let` 共享实例（4 482 → 2 321ms）。
>
> **perf-C 四刀**（同文件）：
> - **B-2** `replace()` 加 `hasMatch` 短路：0 命中场景直接返回原 s，避免一次 NSString.substring 整行复制。
> - **B-3** `htmlEscape` / `htmlEscapePreservingPlaceholders` 加 UTF-8 字节扫 fast-path：行内无 entity-trigger / placeholder 字符即直返原 s。
> - **B-4** `renderInline` 入口加同样 fast-path（trigger 集合：`` ` ! [ * _ ~ ``）：lorem-prose 行直走 htmlEscape，跳过 9 次 enumerateMatches。
> - **B-5** `isThematicBreak` 重写为单 pass char scan，消除原来每行 3 次 `trimmed.filter { ... }`（lorem 65 k 行 × 3 ≈ 16 MB allocation 全免）。**单刀贡献 -1 302ms**。
>
> 累计 5 刀，4 482 → 562 ms，**-87%**，已落 < 1 s 目标，距 < 500 ms 目标剩 62 ms。

### 1.3 仍未覆盖（需后续基线）

- 连续打字 1000 键的 `flushDocSync` 累计时间 + 主线程占用时长（依赖 ScintillaView，需 NSWindow context）。
- 大文件下 `applyAllInlineBlames` 一次的实墙耗时（同上，需 NSView）。
- ColorScanner 已有 baseline，**移出此清单**。
- FindState `query` 字符级抖动下 `highlightAllMatches` 的累计扫描时长（依赖 NSView）。
- Workspace.openFile 端到端 **20MB**（5MB 已达标，20MB 待补，便于发现非线性退化）。

---

## 2. 加载链路（卷轴 1）热点表

> 嫌疑列已根据 § 1.2 perf-A baseline 修订（标 ⭢）。

| # | 位置 | 一句话症状 | 根因 | 嫌疑 |
|---|------|------------|------|------|
| L1 | `Models/Workspace.swift:273–344 openFile(at:)` | — | 已分两层 Task，detached 后台 decode；同步段仅占位 + stat | 低（已优）|
| L2 | `Models/Workspace.swift:380–409 applyLoadResult` | text 灌入 + isLoading=false 后立即请求 git blame | 端到端 5MB 实测 117ms（含 decode），与 #L4 / #L5 / #L8 同帧叠加可能放大 jank | 中 |
| L3 | `Views/ScintillaCodeEditor.swift:441–451 applyText` | `view.setString(整段)` 一次性灌入 Scintilla | 无 chunked apply，超大文件由 large-file 旁路接管，常见档位走全量 | 中 |
| L4 | `Views/Scintilla/Coordinator+InlineBlame.swift:187–202 applyAllInlineBlames` | **逐行调用 SCI_SETINDICOLORFORE 等 Scintilla 装饰 API，O(行数)** | 无 visible-range 优化、无批量 API、无缓存命中短路；attach(view:) L157 首屏触发；blame 解析底层（GitClient.parseBlamePorcelain）实测 ~1MB porcelain 191ms | **高** |
| L5 | `Views/Scintilla/Coordinator+ColorSwatch.swift:54–94 applyColorSwatches` | `view.string()` 全文复制 + `ColorScanner.scan(text)` 全文扫 | ⭢ **已平反**：ColorScanner.scan 5MB 实测仅 11ms。瓶颈不在算法本身，可能在 `view.string()` 复制（依赖 Scintilla NSView，未独测） | 低 |
| L6 | `Views/MarkdownPreviewPane.swift:49–59 updateNSView` | 缓存命中即直接返回；只有 markdown/dark 变化才重新 loadHTML | 不在打开临界路径，独立 sheet。但若 sheet 已开 → 见 #L8 | 低 |
| L7 | `Views/MainWindow.swift body` | NavigationSplitView，@EnvironmentObject 不在 init 触发计算 | SwiftUI 树构建轻量 | 低 |
| **L8** | `Models/MarkdownConverter.swift:51–448 render` | **5MB 单次 render = 4 482ms**（perf-A 实测） | 全量 BlockContext 行扫，无 chunk、无增量、无缓存；preview pane 一开 markdown 文本一改即重渲 | **高** |

### 加载链路 Top 3 嫌疑（修订）

1. **#L8 MarkdownConverter.render 全量重渲** — 实测 4.5s @ 5MB，远超其他热点。**新晋第一**。
2. **#L4 InlineBlame 全行重画** — 解析层 191ms @ 1MB（实测）+ 装饰层 O(行) Scintilla 调用（未独测但定性可疑）。
3. **#L3 setString 单次大块** — Scintilla 内部成本，难绕开，仍与 #L4 / #L8 同帧叠加才是问题。

> ColorScanner / ColorSwatch 已从 Top 3 中移除，由 perf-A baseline 平反。

---

## 3. 输入响应链路（卷轴 2）热点表

| # | 位置 | 一句话症状 | 根因 | 嫌疑 |
|---|------|------------|------|------|
| I1 | `Views/ScintillaCodeEditor.swift:594–600 SCN.MODIFIED → scheduleDocSync` | 每按键即调度一次 50ms 节流 Task | 节流已存在；细节见 #I2 | 中 |
| I2 | `Views/ScintillaCodeEditor.swift:577–586 flushDocSync` | **`let newText = view.string() ?? ""` 全文复制 + 与 `doc.text` 比对** | 大文件走 `isLargeFile` 跳过；**中档文件每 50ms 复制 + diff 一次**，N 越大越贵 | **高** |
| I3 | `Models/Document.swift @Published var text` | text 改 → Document.objectWillChange 发布 | Document 粒度，未污染 Workspace | 低 |
| I4 | `Models/FindState.swift:29–55 @Published query` + `Coordinator+Find.swift:247–262 refreshHighlightsIfNeeded` | **query 字符级改动即触发 redraw → highlightAllMatches，无 debounce** | 有 (query, flags, docLength) 签名缓存避免重复扫，但首次每个新 query 都全扫 | **高** |
| I5 | `Coordinator+InlineBlame.swift:163–186 applyCurrentLineInlineBlame` | UPDATEUI 时仅当前行 O(1) | 有 InlineBlameMode 模式分流；cache miss → 全文重画 | 中 |
| I6 | `Models/GitBlameEngine.swift:83–117 refresh(for:)` | save 后调 refresh，异步 git blame | 不阻塞下一次输入；但完成后会触发 #L4 路径 | 中（间接）|
| I7 | Scintilla undo stack | 无 Swift 层合并，由 Scintilla 自管 | 假设 Scintilla 自己合并连续字符；未实测 | 低 |

### 输入响应 Top 3 嫌疑

1. **#I2 flushDocSync 的 view.string() 全文复制**：中档文件（如 100KB 配置、1MB 日志）打字时每 50ms 复制 + 比对一次整段字符串。
2. ~~**#I4 FindState query 无 debounce**~~ — **phase 45-D 已落地**（150ms RunLoop.main debounce）；连打 N 字符 → `highlightAllMatches` + `.findCurrent` 命令各 1 次。
3. **#I5/I6 GitBlame save → applyAllInlineBlames 全文重画**：与卷轴 1 #L4 同源，save 后会同步触发一次首屏级别的装饰层重排。

---

## 4. Top 候选汇总（综合两卷轴 + perf-A 修订）

| 优先 | 候选 | 影响卷轴 | 实测/估计收益 | 工作量 | 风险 |
|---|---|---|---|---|---|
| **P0** | MarkdownConverter render 增量化（按段缓存 + dirty-range 重渲），或 preview pane 打开期对超阈值文档限速/分块 | 加载 + 输入 | **4 482ms → 562ms（perf-B + perf-C 共 5 刀，-87%）；剩 62ms 可达 < 500ms 目标，但边际收益低，建议收手** | 已落 | 无 |
| **P0** | InlineBlame 改 visible-range 装饰（首屏 + UPDATEUI 都仅装饰可视行） | 加载 + 输入间接 | 大文件首屏 -100~500ms；save 后冻结消失 | 中 | 中（需正确处理 viewport 变化、滚动事件订阅） |
| **P0** | flushDocSync 用 Scintilla **dirty range / SCN.MODIFIED 的 length+position 增量**取代 `view.string()` 全文复制 | 输入 | 中档文件每按键 -1~10ms 主线程 | 中 | 高（diff 路径稍复杂、要兼容 undo / external change） |
| **P1** ✅ | FindState `query` 加 100–150ms debounce + 取消上一次扫 | 输入 | **phase 45-D 落地（150ms RunLoop.main）**：连打 N 字符 → `highlightAllMatches` + `.findCurrent` 命令各 N → 各 1 次 | 已落地 | 低 |
| **P1** ✅ | GitBlame parsePorcelain 后台线程化（核对 callsite 是否已切线程） | 加载 | **核对结论：已落地。** `GitClient.blame` / `parseBlamePorcelain` / `currentUserName` 全部 `nonisolated static`；唯一生产 callsite `GitBlameEngine.request:91-92` 已在 `Task.detached(.userInitiated)` 内；解析全程 off-main，仅 dictionary fill 回 main actor。phase 45-E 入仓 3 例 actor-isolation 回归测试。 | 已落地（仅补回归测试） | 低 |
| **P2** | applyAllInlineBlames 改批量 Scintilla API（一次 message 设多行 indicator） | 加载 | -30~50%（需 profile 确认 Scintilla 是否提供批量 API） | 中 | 中（依赖 Scintilla 实现，可能要扩 Vendor） |
| **P2** | Workspace `objectWillChange.send()` 路径审计（确保非编辑路径不污染 Document 流） | 输入 | 减少不必要 SwiftUI redraw | 低 | 低 |
| ~~P*~~ | ~~ColorScanner / ColorSwatch viewport-only~~ | — | ~~已平反，11ms @ 5MB~~ | — | — |

---

## 5. 验证路径建议

### 5.1 baseline（perf-A 已落地 ✓）

`Tests/ScribeTests/PerformanceTests.swift` 现有 8 例（4 旧 + 4 新）。落地清单：

| 用例 | 状态 | 当前数值 |
|---|---|---|
| `test_colorScanner_scan_5mb_baseline` | ✓ 入仓 | 11ms |
| `test_gitBlame_parsePorcelain_synthetic_baseline` | ✓ 入仓 | 191ms |
| `test_markdownConverter_render_5mb_baseline` | ✓ 入仓 | 4 482ms |
| `test_workspace_openFile_endToEnd_5mb_baseline` | ✓ 入仓 | 117ms |

**仍欠 baseline**（依赖 NSView / NSWindow context，纯 unit-test 框架内难独测）：

- `test_applyAllInlineBlames_<size>_baseline` — 需 ScintillaView 实例
- `test_flushDocSync_typing_burst_baseline` — 同上
- `test_findHighlight_<size>_baseline` — 同上
- 解决路径：写 UI test target 或在 Coordinator 测试中 mock NSWindow（次步再议）。

### 5.2 instrument profile（一次性 — 后续手测）

- **Time Profiler**：打开 20MB fixture，记录从 `openFile` 到 `applyAllInlineBlames` 完成的火焰图。
- **System Trace**：连续打字 5 秒，看 `flushDocSync` 与 markdown preview 同时开启时主线程占比。
- **Markdown render**：用 5MB lorem 作 markdown 输入跑一次，重点看 BlockContext.process 火焰图分布（`flushParagraph` 与 `processNonTable` 谁更重）。

> ⚠ Profile 数据建议存 `docs/perf_traces/<日期>.trace`，不入 git（.gitignore 加目录）。

### 5.3 优化 → 验证闭环（每个候选）

```
1. 写 perf test，设当前 baseline ±10% 红线
2. 改源
3. perf test pass + 全 607 套件全绿
4. release 构建跑一次，看是否触发其他 budget 退化
```

---

## 6. 钉死的边界（沿用 NEXT_SESSION.md）

- ✗ 不引 macOS 26 Liquid Glass、不重写 Scintilla 桥接为 TextKit2
- ✗ 不动 LargeFilePolicy 阈值（已稳）
- ✗ 不引第三方 profiler / metric 框架
- ✓ XCTest measure block / `DispatchTime` 手测
- ✓ Scintilla 增量 API（若 Vendor 支持）
- ✓ Combine debounce / throttle、Task.sleep + cancel

---

## 7. 推进进度

- ✅ **A — perf-A baseline**（4 条用例 + 实测数值）— 2026-05-01 17:51 入仓
- ✅ **B — perf-B：MarkdownConverter regex 编译单次化** — 2026-05-01 18:13 入仓，4 482 → 2 321ms（-48%）
- ✅ **C — perf-C：MarkdownConverter 4 处 fast-path** — 2026-05-01 19:30 入仓，2 321 → **562ms（累计 -87%）**
  - B-2 `replace()` hasMatch 短路
  - B-3 `htmlEscape` / `htmlEscapePreservingPlaceholders` UTF-8 字节扫 fast-path
  - B-4 `renderInline` 入口同样 fast-path
  - B-5 `isThematicBreak` 单 pass 重写（**单刀 -1 302ms**）
- ✅ **D — phase 45-D：FindState query debounce（P1 #1）** — 2026-05-01 22:33 入仓
  - 加 `@Published debouncedQuery`，由 `query` 经 150ms RunLoop.main debounce 派生
  - `Coordinator+Find.refreshHighlightsIfNeeded` 改用 `debouncedQuery` 决定是否扫；`query.isEmpty` 仍立即清高亮
  - `FindBar onChange(of: state.debouncedQuery)`（toggle 路径不动）
  - 新增 `FindStateDebounceTests` 4 例
  - 收益：连打 N 字符 → `highlightAllMatches` + `.findCurrent` 命令各 N 次 → 各 1 次
- ✅ **E — phase 45-E：GitBlame 后台线程化勘验（P1 #2）** — 2026-05-02 入仓
  - **核对结论**：生产代码早就把 `git blame` shell-out + porcelain 解析 + `currentUserName` 全部包在 `Task.detached(.userInitiated)` 内（`GitBlameEngine.request:83-97`）；仅 `handleResult` 的 dictionary fill 回 main actor。无 main-actor 阻塞瓶颈。
  - 新增 `GitBlameEngineActorTests` 3 例 actor-isolation 回归保护：
    - `test_request_doesNotSynchronouslyFillCache` — 同步窗口内 cache 必空
    - `test_refresh_dropsCacheSyncAndReFetchesAsync` — refresh 同步清缓存 + 异步 re-fetch
    - `test_request_inFlightCollapsesDuplicateCalls` — 5 次连发只 land 一次
- ⏳ **下一战 — 等魔尊钦定**：
  - 转 P0 #2：InlineBlame visible-range 装饰（需先建 Scintilla NSView 测试 harness）
  - 转 P0 #3：flushDocSync 增量同步（同上）
- ⏳ **C — Instrument 手测**（Time Profiler / System Trace）— 仍待人工执行（agent 内不可跑）。


---

## 附 A：关键文件速查

```
Models/Workspace.swift                        openFile / applyLoadResult
Models/Document.swift                         @Published text 源头
Models/FindState.swift                        query 抖动源
Models/GitBlameEngine.swift                   request / refresh / invalidate
Views/ScintillaCodeEditor.swift               applyText / scheduleDocSync / flushDocSync
Views/Scintilla/Coordinator+InlineBlame.swift applyAllInlineBlames / applyCurrentLineInlineBlame
Views/Scintilla/Coordinator+ColorSwatch.swift applyColorSwatches
Views/Scintilla/Coordinator+Find.swift        refreshHighlightsIfNeeded / highlightAllMatches
```

## 附 B：实测复现命令

```bash
# 已有 perf 套件（release）
swift test --filter PerformanceTests -c release 2>&1 | tail -40

# 全套（release）
swift test -c release 2>&1 | tail -10

# 单 fixture 生成（如缺失）
bash Scripts/gen_perf_samples.sh
```
