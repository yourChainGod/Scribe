//
//  ScribeScintillaUmbrella.h
//  Umbrella header that bridges Scintilla's vendored layout to the SwiftPM
//  module map sitting next to it. Added by Scribe (not upstream).
//
//  Same-directory imports (e.g. `Scintilla.h`) issued by ScintillaView.h
//  resolve here automatically because this file lives in the include/ dir
//  alongside the public Scintilla API headers.
//

#pragma once

// Pull in the Cocoa view declarations. ../cocoa/* relative paths keep us
// from having to add a header search path at module-build time.
#import "../cocoa/ScintillaView.h"
#import "../cocoa/InfoBar.h"
