//
//  main.swift
//  Voz — Local Speech-to-Text desktop app
//
//  Entry point. We use an explicit main.swift (instead of @main) so the app
//  can set up as a pure AppKit process and then host SwiftUI in its window.
//  Voz is a regular app now: a dock icon and a main window, plus a menu-bar
//  status item and a global hotkey for quick dictation anywhere.
//

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Regular app: dock icon + window. (AppDelegate also sets this on launch.)
app.setActivationPolicy(.regular)
app.run()
