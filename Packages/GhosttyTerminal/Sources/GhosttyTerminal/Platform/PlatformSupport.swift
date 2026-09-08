//
//  PlatformSupport.swift
//  libghostty-spm
//

// The library's one platform assertion.
//
// Every other file guards its code with `#if canImport(AppKit)` — none of
// them carries an `#else` arm of its own, so a target without AppKit would
// quietly compile all of them to nothing. The failure is stated once, here,
// in a file that is always compiled and has no other content to distract
// from it. (Legacy `#if canImport(UIKit)` branches elsewhere are inert on
// macOS and kept only until they are pruned.)
#if !canImport(AppKit)
    #error("Unsupported platform: libghostty-spm requires AppKit.")
#endif
