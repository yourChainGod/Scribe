//
//  ScribeScintillaTextRangeBridge.mm
//  ObjC++ implementation of ScribeScintillaTextRangeBridge.h.
//  Added by Scribe; not part of upstream Scintilla.
//

#import "ScribeScintillaTextRangeBridge.h"
#import "ScintillaView.h"
#include "../include/Scintilla.h"

NSData *ScribeReadTextRange(void *view,
                            NSInteger start,
                            NSInteger length) {
    if (view == nullptr || length <= 0) {
        return [NSData data];
    }
    // ARC-aware bridge cast: the caller still owns `view`. We borrow
    // the reference for the duration of the message dispatch and
    // never retain it, so there's no ownership ambiguity to leak.
    ScintillaView *scintillaView = (__bridge ScintillaView *)view;

    // dataWithLength returns a zero-filled NSMutableData; on OOM it
    // returns nil, which the bridge contract surfaces as a nil
    // result back to Swift.
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
    if (data == nil) {
        return nil;
    }

    // Scintilla writes exactly (cpMax - cpMin) bytes plus a trailing
    // NUL into lpstrText. To avoid OOB write of that NUL we allocate
    // one extra byte up front and trim afterwards.
    [data setLength:(NSUInteger)(length + 1)];

    // Sci_TextRangeFull uses Sci_Position (not Sci_PositionCR) for
    // both cpMin and cpMax — that's a 64-bit ptrdiff_t on every
    // Apple-supported architecture, which is what gives us the
    // > 2 GB safety the FULL variant exists to provide.
    Sci_TextRangeFull tr;
    tr.chrg.cpMin = (Sci_Position)start;
    tr.chrg.cpMax = (Sci_Position)(start + length);
    tr.lpstrText  = (char *)data.mutableBytes;

    [scintillaView message:SCI_GETTEXTRANGEFULL
                   wParam:0
                   lParam:(sptr_t)&tr];

    // Trim the trailing NUL — callers expect raw bytes, not C-string.
    [data setLength:(NSUInteger)length];
    return data;
}
