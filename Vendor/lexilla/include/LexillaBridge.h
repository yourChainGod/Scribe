//
//  LexillaBridge.h
//  ObjC façade over Lexilla's C++ public API. Added by Scribe — not part
//  of upstream Lexilla. Lets Swift call into Lexilla without seeing the
//  Scintilla::ILexer5 C++ class directly.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Allocate a fresh `Scintilla::ILexer5 *` for the named lexer
/// (e.g. "cpp", "python", "json", "html"). Returns NULL when Lexilla
/// has no lexer by that name. The caller hands the pointer to
/// `ScintillaView` via `SCI_SETILEXER` (`message: 4033`); ownership
/// transfers to Scintilla, which calls `Release()` when the document is
/// destroyed or the lexer is replaced.
void * _Nullable LexillaBridgeCreateLexer(const char *name);

/// Number of lexers compiled into the Lexilla static library. Useful for
/// populating UI menus.
int LexillaBridgeLexerCount(void);

/// All lexer names known to the Lexilla static library, in the order
/// `GetLexerName()` returns them.
NSArray<NSString *> *LexillaBridgeLexerNames(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
