//
//  ScribeScintillaLoaderBridge.mm
//  ObjC++ implementation of the ScribeScintillaLoaderBridge.h façade.
//  Added by Scribe; not part of upstream Scintilla.
//
//  Pulls in `ILoader.h` (relative path so we don't need a header
//  search-path entry just for this file) and casts the `void *`
//  pointer Swift hands us back to the C++ abstract type before
//  dispatching the virtual call.
//

#import "ScribeScintillaLoaderBridge.h"

// Relative include keeps this file self-contained — Lexilla uses the
// same pattern for ILexer.h. The vendored Scintilla doesn't expose
// ILoader.h via the public umbrella because it's C++-only.
#include "../include/ILoader.h"

using Scintilla::ILoader;

int ScribeLoaderAddData(void *loader,
                        const void *bytes,
                        NSInteger length) {
    if (loader == nullptr) {
        // Treated as a non-success status code so the Swift wrapper
        // can surface "couldn't append" without distinguishing nil
        // from a real Scintilla failure.
        return -1;
    }
    auto *l = static_cast<ILoader *>(loader);
    return l->AddData(static_cast<const char *>(bytes),
                      static_cast<Sci_Position>(length));
}

void *ScribeLoaderConvertToDocument(void *loader) {
    if (loader == nullptr) {
        return nullptr;
    }
    auto *l = static_cast<ILoader *>(loader);
    return l->ConvertToDocument();
}

void ScribeLoaderRelease(void *loader) {
    if (loader == nullptr) {
        return;
    }
    static_cast<ILoader *>(loader)->Release();
}
