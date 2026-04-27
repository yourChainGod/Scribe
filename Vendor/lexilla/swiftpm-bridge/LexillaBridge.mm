//
//  LexillaBridge.mm
//  ObjC++ implementation of the LexillaBridge.h façade. Added by Scribe;
//  not part of upstream Lexilla.
//

#import "LexillaBridge.h"

// Pull in Scintilla's ILexer first so Lexilla.h's `using Scintilla::ILexer5`
// resolves. Path is relative because we don't add Scintilla's include
// directory to Lexilla's header search path at this layer — and we don't
// need to: ILexer.h is only consumed inside this .mm.
#include "../../scintilla/include/ILexer.h"
#include "Lexilla.h"

void *LexillaBridgeCreateLexer(const char *name) {
    if (name == nullptr) {
        return nullptr;
    }
    // CreateLexer hands back an `Scintilla::ILexer5 *`; Scintilla expects
    // the same pointer back through SCI_SETILEXER, so a void* round-trip
    // through Swift is type-safe in practice.
    return static_cast<void *>(CreateLexer(name));
}

int LexillaBridgeLexerCount(void) {
    return GetLexerCount();
}

NSArray<NSString *> *LexillaBridgeLexerNames(void) {
    const int n = GetLexerCount();
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:(NSUInteger)n];
    char buf[128];
    for (int i = 0; i < n; ++i) {
        buf[0] = '\0';
        GetLexerName(static_cast<unsigned int>(i), buf, sizeof(buf));
        if (buf[0] != '\0') {
            NSString *name = [NSString stringWithUTF8String:buf];
            if (name != nil) {
                [out addObject:name];
            }
        }
    }
    return [out copy];
}
