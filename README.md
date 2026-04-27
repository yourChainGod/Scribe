# Scribe

> A native macOS text editor inheriting the spirit of [notepad--](https://gitee.com/cxasm/notepad--), reborn in SwiftUI.

**Status**: Phase 0.1 — UI 骨架 + AppKit 编辑器桥  
**Platform**: macOS 13+ (Ventura)  
**Stack**: Swift 6 · SwiftUI · AppKit (where needed)  
**License**: GPL-3.0 (aligned with upstream ndd; required for porting ndd C++ core)

---

## Why Scribe?

`notepad--` 在 Qt 上做到了跨平台与功能丰富，但 Qt5 Widgets 在 macOS 上的美学已碰天花板。Scribe 抛弃 Qt，从零用 SwiftUI 构筑一款**真正 macOS 原生**的文本/代码编辑器，复用 ndd 的算法智慧（diff、编码检测、大文件、HEX）但完全脱离 Qt 依赖。

## Goals

- 🎨 **macOS 原生美学**：原生标题栏、SF Symbols、流畅动画、暗色无缝
- ⚡ **高性能**：原生渲染，启动 < 200ms
- 🧬 **传承 ndd 算法**：复用其久经考验的 diff、编码、大文件分页逻辑（去 Qt 化）
- 🔓 **专注 Mac**：放弃跨平台，做到极致

## Non-Goals

- ❌ Windows / Linux 支持（保留给上游 ndd）
- ❌ 在所有方面对齐 ndd（只取核心功能）

## Architecture (planned)

```
┌────────────────────────────────────────────┐
│  SwiftUI Layer                             │
│  主窗口 / 工具栏 / 侧栏 / 标签 / 状态栏    │
└────────────────────────────────────────────┘
                 │ Swift APIs
                 ↓
┌────────────────────────────────────────────┐
│  Swift Service Layer                       │
│  DocumentManager · FileService · Theme     │
└────────────────────────────────────────────┘
                 │ Objective-C++ bridge
                 ↓
┌────────────────────────────────────────────┐
│  C++ Core (ported from ndd, Qt-free)       │
│  Encoding · Diff · LargeFile · HexView     │
└────────────────────────────────────────────┘
                 │
                 ↓
┌────────────────────────────────────────────┐
│  Scintilla (Cocoa port) — code editor      │
└────────────────────────────────────────────┘
```

## Build & Run

```bash
swift run Scribe
```

Requires Xcode 15+ / Swift 6+.

## License

**GPL-3.0** — see [`LICENSE`](LICENSE).

Aligned with upstream [`notepad--`](https://gitee.com/cxasm/notepad--).
Phase 2+ will port ndd's C++ core (`Encode.cpp`, `CmpareMode.cpp`, HEX view),
which is GPL-3.0; under copyleft, the resulting work must remain GPL-3.0.
