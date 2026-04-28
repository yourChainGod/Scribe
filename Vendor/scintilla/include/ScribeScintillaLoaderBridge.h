//
//  ScribeScintillaLoaderBridge.h
//  Phase 34a — ObjC façade over Scintilla's `Scintilla::ILoader` C++ API.
//  Added by Scribe; not part of upstream Scintilla.
//
//  Why a bridge:
//    `SCI_CREATELOADER` returns an opaque `ILoader *` that Swift can
//    only hold as `Int` (sptr_t). The pointer is a C++ object with
//    virtual methods (AddData / ConvertToDocument / Release) that
//    Swift cannot dispatch to directly — they live on the C++ vtable.
//    A C-callable ObjC++ shim casts the void* back to `ILoader *` and
//    forwards the call. Same shape as `LexillaBridge` does for
//    Lexilla's `ILexer5 *`.
//
//  Lifetime:
//    The loader is owned by the caller until either:
//      - `ScribeLoaderConvertToDocument` succeeds (the loader is
//        consumed; the returned doc pointer is now refcount-owned by
//        Scintilla once you `SCI_SETDOCPOINTER` it — call SCI_
//        RELEASEDOCUMENT on the *previous* doc, not the new one),
//      - or `ScribeLoaderRelease` is called explicitly (cancel path).
//    Calling AddData on a converted/released loader is undefined.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Append `length` bytes from `bytes` to `loader`. Returns 0
/// (`SC_STATUS_OK`) on success, non-zero on failure (typically
/// `SC_STATUS_BADALLOC` if Scintilla's gap buffer can't grow).
/// `loader` should normally be a non-null pointer obtained from
/// `SCI_CREATELOADER`, but passing nil is treated as -1 so the
/// Swift wrapper can route its defensive paths through here without
/// special-casing.
int ScribeLoaderAddData(void * _Nullable loader,
                        const void * _Nullable bytes,
                        NSInteger length);

/// Convert `loader` to a document pointer ready for
/// `SCI_SETDOCPOINTER`. After this call the loader is consumed; do not
/// invoke `*Loader*` calls on the same pointer. Returns nil if the
/// loader was nil.
void * _Nullable ScribeLoaderConvertToDocument(void * _Nullable loader);

/// Manually release a loader without converting it (cancel path).
/// No-op when `loader` is nil. Don't call this *after*
/// `ScribeLoaderConvertToDocument` — the loader is already gone.
void ScribeLoaderRelease(void * _Nullable loader);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
