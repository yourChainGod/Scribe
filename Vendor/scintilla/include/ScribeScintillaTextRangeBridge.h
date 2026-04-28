//
//  ScribeScintillaTextRangeBridge.h
//  Phase 34c — façade over `SCI_GETTEXTRANGEFULL` so Swift can pull
//  arbitrary [start, end) byte windows out of a Scintilla document
//  without the chunked save path having to construct a
//  `Sci_TextRangeFull` C struct from Swift via raw pointer dance.
//
//  Why a separate shim:
//    - `Sci_TextRangeFull` is a plain C struct whose lifetime is one
//      message dispatch; building it correctly from Swift means
//      hand-rolling 24-byte aligned storage and trusting layout
//      invariants Scintilla doesn't formally guarantee.
//    - The ObjC++ side already speaks `SCI_*` natively, can use
//      `Sci_PositionFull` directly (64-bit positions on every Apple
//      arch), and produces an `NSData` that crosses back to Swift as
//      a Sendable value. No lifetime ambiguity at the boundary.
//
//  Lifetime / threading contract:
//    - `view` MUST be a live `ScintillaView`; pass `(__bridge void *)`
//      from the ObjC side or the equivalent Swift `Unmanaged.toOpaque()`.
//    - Caller must invoke from the main actor — `ScintillaView`
//      message dispatch reaches into the live NSView hierarchy and
//      is not thread-safe.
//
//  Added by Scribe; not part of upstream Scintilla.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Read `length` bytes starting at `start` from `view`'s buffer into
/// a fresh `NSData`. Uses `SCI_GETTEXTRANGEFULL` whose
/// `Sci_PositionFull` is 64-bit, so reads beyond the 2 GB 32-bit cap
/// work on TEXT_LARGE documents.
///
/// Returns:
///   - empty `NSData` when `length <= 0` or `view == nil` (no error
///     surface — empty range is a valid, idempotent read);
///   - nil only when `NSMutableData` itself can't allocate `length`
///     bytes (catastrophic OOM); callers should treat that as a
///     fatal save error.
NSData * _Nullable ScribeReadTextRange(void * _Nullable view,
                                       NSInteger start,
                                       NSInteger length);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
