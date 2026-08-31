//
//  AppDelegate.swift
//  Voz
//
//  Coordinator: owns the status-bar item + menu, wires up the global hotkey,
//  and runs the core loop:  trigger → record → (trigger again) → transcribe → paste.
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let hotKeys = HotKeyManager()
    private let meeting = MeetingRecorder()
    private var mainWindow: NSWindow?
    private let app = AppState.shared

    private enum State { case idle, recording, transcribing }
    private var state: State = .idle { didSet { updateStatusIcon(); syncAppState() } }

    private func syncAppState() {
        switch state {
        case .idle:         app.status = .idle
        case .recording:    app.status = .recording
        case .transcribing: app.status = .transcribing
        }
    }

    // Menu items we mutate at runtime.
    private var toggleItem: NSMenuItem!
    private var hotkeyInfoItem: NSMenuItem!
    private let modelSubmenu = NSMenu()   // populated from downloaded models

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock icon + window by default, or menu-bar-only if the user prefers.
        // Either way the status item + global hotkey always keep running.
        applyActivationPolicy()
        if let logo = BrandLogo.iconImage { NSApp.applicationIconImage = logo }

        setupMainMenu()
        setupStatusItem()
        wireAppState()
        hotKeys.onTrigger = { [weak self] in self?.handleTrigger() }
        hotKeys.start()

        showMainWindow()

        // Nudge for Accessibility permission early so ⌘V paste works later.
        if !Paster.hasAccessibilityPermission {
            Paster.promptForAccessibilityPermission()
        }
    }

    /// Reopen the window when the dock icon is clicked and no window is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// Keep Voz running (status item + hotkey) after the window is closed — it's
    /// a menu-bar app at heart, not a document window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon + app switcher (.regular) or menu-bar-only (.accessory), per the
    /// user's Settings choice. The status item and global hotkey work in both.
    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(Settings.shared.dockIconVisible ? .regular : .accessory)
    }

    // MARK: - Main window (SwiftUI)

    private func wireAppState() {
        app.onToggleRecord = { [weak self] in self?.handleTrigger() }
        app.onTranscribeFiles = { [weak self] urls in self?.transcribeFiles(urls) }
        app.onOpenShortcutPrefs = { [weak self] in self?.openPreferences() }
        app.onReloadHotkey = { [weak self] in
            self?.hotKeys.restart()
            self?.refreshHotkeyInfo()
        }
        app.onStartMeeting = { [weak self] in self?.startMeeting() }
        app.onStopMeeting = { [weak self] notes in self?.stopMeeting(notes: notes) }
        app.onUpdateActivationPolicy = { [weak self] in
            self?.applyActivationPolicy()
            // Coming back to .regular: make sure a window is visible again.
            if Settings.shared.dockIconVisible { self?.showMainWindow() }
        }
        app.refreshModelName()
    }

    private func showMainWindow() {
        if let w = mainWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = RootView().environmentObject(app)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Voz"
        // Transparent, full-height title bar so the sidebar's brand gradient
        // flows up behind the traffic-light buttons and fades into the content.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 940, height: 640))
        window.center()
        window.isReleasedWhenClosed = false
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.stop()
    }

    // MARK: - Main menu (top-left menu bar)

    /// Builds the standard app/Edit/Window menus. Without this the app has no
    /// menu bar, so ⌘Q, ⌘C/⌘V, etc. don't work like a normal Mac app.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (shown under the bold "Voz" title).
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Voz",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        // No "Check for Updates…" here. Voz tells you when there is one, and the
        // version card at the foot of the sidebar is where you check on demand
        // -- one place that answers "what am I running, and is it current?"
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openPreferences), keyEquivalent: ",")
        settings.target = self
        let perms = appMenu.addItem(withTitle: "Permissions…", action: #selector(openPermissionsFromMenu), keyEquivalent: "")
        perms.target = self
        appMenu.addItem(.separator())
        let services = NSMenu()
        let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Voz", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Voz", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu — makes ⌘X/C/V/A and undo work in text fields.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu.
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openPermissionsFromMenu() {
        app.selectedTab = .settings
        showMainWindow()
    }

    // MARK: - Status bar & menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Start Recording",
                                action: #selector(toggleFromMenu), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let openItem = NSMenuItem(title: "Open Voz Window",
                                  action: #selector(openMainFromMenu), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        // Model submenu — quick one-click switching between downloaded models.
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelSubmenu
        menu.addItem(modelItem)

        hotkeyInfoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hotkeyInfoItem.isEnabled = false
        menu.addItem(hotkeyInfoItem)

        let prefs = NSMenuItem(title: "Preferences…",
                               action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)


        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Voz", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.delegate = self   // so we refresh the model list / checkmark on open
        statusItem.menu = menu
        rebuildModelSubmenu()
        refreshHotkeyInfo()
    }

    // Refresh the model list + hotkey label each time the menu opens, so newly
    // downloaded models appear and the checkmark tracks the active model.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == statusItem.menu else { return }
        rebuildModelSubmenu()
        refreshHotkeyInfo()
    }

    private func rebuildModelSubmenu() {
        modelSubmenu.removeAllItems()
        let current = Settings.shared.modelPath
        let models = WhisperModels.available
        if models.isEmpty {
            let none = NSMenuItem(title: "No models found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            modelSubmenu.addItem(none)
            return
        }
        for m in models {
            let item = NSMenuItem(title: WhisperModels.labelWithSize(forPath: m.path),
                                  action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = m.path
            item.state = (m.path == current) ? .on : .off   // checkmark on active
            modelSubmenu.addItem(item)
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        Settings.shared.modelPath = path
        rebuildModelSubmenu()
        app.refreshModelName()
        VozLog.log("model switched to \(path)")
    }

    /// The Voz brand mark, sized for the menu bar and set as a template so macOS
    /// renders it black on light menu bars / white on dark ones.
    private static let statusLogo: NSImage? = {
        guard let img = NSImage(named: "MenuBarLogo")
            ?? Bundle.main.url(forResource: "MenuBarLogo", withExtension: "png").flatMap({ NSImage(contentsOf: $0) })
        else { return nil }
        // 18pt tall (standard menu-bar height), aspect preserved so it isn't
        // squished or off-center; the source is high-res so it stays crisp.
        let aspect = img.size.height > 0 ? img.size.width / img.size.height : 1
        img.size = NSSize(width: 18 * aspect, height: 18)
        img.isTemplate = true
        return img
    }()

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        button.image = Self.statusLogo
        // Center the icon: NSButton defaults to .imageLeft (image left of the
        // title slot), which pushes a title-less status icon off to the side.
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        (button.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        switch state {
        case .idle:         button.contentTintColor = nil;            button.toolTip = "Voz — idle"
        case .recording:    button.contentTintColor = .systemRed;     button.toolTip = "Voz — recording"
        case .transcribing: button.contentTintColor = .secondaryLabelColor; button.toolTip = "Voz — transcribing"
        }
        toggleItem?.title = (state == .recording) ? "Stop Recording" : "Start Recording"
    }

    private func refreshHotkeyInfo() {
        switch Settings.shared.triggerMode {
        case .hotKey:
            hotkeyInfoItem.title = "Trigger: \(Settings.shared.hotKey.displayString)"
        case .fnDoubleTap:
            hotkeyInfoItem.title = "Trigger: Double-tap Fn"
        }
    }

    // MARK: - Actions

    @objc private func toggleFromMenu() { handleTrigger() }

    @objc private func openMainFromMenu() { showMainWindow() }

    @objc private func openPreferences() {
        // Settings now live inside the main window's Settings tab.
        app.selectedTab = .settings
        showMainWindow()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Core loop

    /// Fired by the hotkey or the menu. Toggles recording on/off.
    private func handleTrigger() {
        VozLog.log("trigger fired, state=\(state)")
        // A meeting owns the mic; don't let the hotkey spin up a second recorder.
        guard app.meetingPhase == .idle || app.meetingPhase == .done else {
            app.flash("Meeting in progress")
            return
        }
        switch state {
        case .idle:         startRecording()
        case .recording:    stopRecordingAndTranscribe()
        case .transcribing: VozLog.log("ignored: mid-transcription")
        }
    }

    private func startRecording() {
        recorder.ensurePermission { [weak self] access in
            guard let self = self else { return }
            VozLog.log("mic permission = \(access)")
            guard access == .granted else {
                self.handleMicDenied(access)
                return
            }
            let ok = self.recorder.start()
            VozLog.log("recorder.start() -> \(ok)")
            guard ok else {
                self.notify("Couldn't start recording", "The microphone may be in use.")
                return
            }
            self.state = .recording
            Sound.play(.start)
            VoiceBarController.shared.show(
                level: { [weak self] in self?.recorder.currentLevel() ?? 0 },
                onClose: { [weak self] in self?.cancelDictation() })
            self.installEscapeMonitor()
        }
    }

    /// Cancel an in-progress dictation from the voice bar's × or the Escape key —
    /// stop recording, discard the audio, transcribe nothing, paste nothing.
    private func cancelDictation() {
        guard state == .recording else { return }
        removeEscapeMonitor()
        VoiceBarController.shared.hide()
        let url = recorder.stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        Sound.play(.stop)
        state = .idle
    }

    // Escape-to-cancel — active only while recording. A global monitor catches
    // Escape when you're focused in another app (dictation's normal case); a
    // local one covers Voz's own windows. Global monitors can only observe, so
    // Escape still reaches the focused app too (harmless in a text field).
    private var escapeMonitors: [Any] = []

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelDictation() }   // 53 = Escape
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancelDictation(); return nil }
            return event
        }
        escapeMonitors = [global, local].compactMap { $0 }
    }

    private func removeEscapeMonitor() {
        escapeMonitors.forEach { NSEvent.removeMonitor($0) }
        escapeMonitors = []
    }

    private func stopRecordingAndTranscribe() {
        removeEscapeMonitor()
        VoiceBarController.shared.hide()
        guard let fileURL = recorder.stop() else {
            VozLog.log("recorder.stop() returned nil url")
            state = .idle
            return
        }
        Sound.play(.stop)
        state = .transcribing
        VozLog.log("transcribing model=\(Settings.shared.modelPath) lang=\(Settings.shared.language)")

        transcriber.transcribe(audioURL: fileURL) { [weak self] result in
            guard let self = self else { return }
            self.state = .idle
            try? FileManager.default.removeItem(at: fileURL) // clean up temp wav

            switch result {
            case .success(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                VozLog.log("SUCCESS trimmedLen=\(trimmed.count) text=\"\(trimmed.prefix(120))\"")
                // Silently do nothing if no speech was detected (no popup).
                guard !trimmed.isEmpty else { VozLog.log("empty -> nothing pasted"); return }

                // Record it in history (persisted, shown in the window).
                self.app.addHistory(HistoryEntry(
                    text: trimmed, date: Date(), source: "Dictation",
                    model: WhisperModels.friendlyName(Settings.shared.modelPath)))

                if Paster.hasAccessibilityPermission {
                    Paster.paste(trimmed)
                } else {
                    // No Accessibility permission → can't send ⌘V. Copy the text
                    // so it isn't lost, prompt for permission, and tell the user.
                    Paster.copyToClipboard(trimmed)
                    Paster.promptForAccessibilityPermission()
                    self.notify("Copied to clipboard — press ⌘V",
                                "Voz needs Accessibility permission to paste automatically. "
                                + "Enable Voz under System Settings → Privacy & Security → Accessibility, "
                                + "then quit and reopen Voz. Your text is on the clipboard now.")
                }
            case .failure(let error):
                VozLog.log("FAILURE \(error.localizedDescription)")
                self.notify("Voz", error.localizedDescription)
            }
        }
    }

    // MARK: - File transcription (from the Files tab)

    /// Transcribes dropped/chosen media files one at a time, adding each result
    /// to history. Does not paste (these aren't live dictation).
    private func transcribeFiles(_ urls: [URL]) {
        guard state == .idle else {
            app.flash("Busy — try again in a moment")
            return
        }
        var queue = urls
        transcribeNext(&queue)
    }

    private func transcribeNext(_ queue: inout [URL]) {
        guard !queue.isEmpty else { return }
        let url = queue.removeFirst()
        var remaining = queue
        state = .transcribing
        app.flash("Transcribing \(url.lastPathComponent)…")
        VozLog.log("file transcribe \(url.lastPathComponent)")

        transcriber.transcribeFile(url) { [weak self] result in
            guard let self = self else { return }
            self.state = .idle
            switch result {
            case .success(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.app.flash("No speech found in \(url.lastPathComponent)")
                } else {
                    self.app.addHistory(HistoryEntry(
                        text: trimmed, date: Date(), source: url.lastPathComponent,
                        model: WhisperModels.friendlyName(Settings.shared.modelPath)))
                    self.app.flash("Transcribed \(url.lastPathComponent)")
                }
            case .failure(let error):
                self.notify("Couldn't transcribe \(url.lastPathComponent)", error.localizedDescription)
            }
            // Continue with the rest of the queue.
            if !remaining.isEmpty { self.transcribeNext(&remaining) }
        }
    }

    // MARK: - Meeting capture

    private func startMeeting() {
        recorder.ensurePermission { [weak self] access in
            guard let self = self else { return }
            guard access == .granted else {
                self.handleMicDenied(access)
                return
            }
            // Capturing the other side of a call needs Screen Recording. Ask for
            // it *before* starting, so the user gets the system prompt at the
            // moment it makes sense rather than a mic-only recording and a
            // toast explaining what they missed.
            guard self.ensureScreenRecordingForMeetings() else { return }

            Task {
                let sys = await self.meeting.start()
                await MainActor.run {
                    self.app.meetingCapturingSystem = sys
                    self.app.meetingTranscript = ""
                    self.app.meetingPhase = .recording
                    Sound.play(.start)
                    if !sys {
                        self.app.flash("Recording your mic only — the call audio isn't being captured.")
                    }
                }
            }
        }
    }

    /// Screen Recording gate for meetings. Returns true if capture can proceed.
    ///
    /// Two things make this worth spelling out to the user. macOS calls the
    /// permission "Screen Recording", which sounds far more invasive than what
    /// Voz does with it — it keeps the audio and discards every video frame. And
    /// approving it does not take effect until the app is relaunched, so without
    /// saying so the user grants it, comes back, and finds nothing changed.
    private func ensureScreenRecordingForMeetings() -> Bool {
        if SystemPermissions.screenRecordingGranted { return true }

        let neverAsked = !UserDefaults.standard.bool(forKey: "VozAskedScreenRecording")
        UserDefaults.standard.set(true, forKey: "VozAskedScreenRecording")

        if neverAsked {
            // Puts up the system prompt. Returns false even when the user then
            // approves — a relaunch is required either way.
            SystemPermissions.requestScreenRecording()
            notify("Allow Voz to record meeting audio",
                   "Meetings capture what the other people say, which macOS puts behind its "
                   + "“Screen Recording” permission.\n\n"
                   + "Voz records the audio only. It never captures, saves or sends any image "
                   + "of your screen.\n\n"
                   + "Approve Voz in the prompt, then quit and reopen Voz — macOS only applies "
                   + "this permission on a fresh launch. Dictation works without it.")
        } else {
            SystemPermissions.openScreenRecording()
            notify("Turn on Screen Recording for Voz",
                   "System Settings is open at Privacy & Security → Screen & System Audio "
                   + "Recording. Switch Voz on, then quit and reopen Voz.\n\n"
                   + "This is what lets a meeting capture the other side of the call. Voz "
                   + "records the audio only — never an image of your screen. Dictation "
                   + "works without it.")
        }
        return false
    }

    private func stopMeeting(notes: String) {
        app.meetingPhase = .transcribing
        Sound.play(.stop)
        let meetingModel = Settings.shared.meetingModelPath
        Task { [weak self] in
            guard let self = self else { return }
            let (sysURL, micURL) = await self.meeting.stop()
            let result = self.buildMeetingTranscript(sysURL: sysURL, micURL: micURL, model: meetingModel)
            await MainActor.run {
                switch result {
                case .success(let transcript):
                    self.saveAndAnalyzeMeeting(transcript: transcript, notes: notes, model: meetingModel)
                case .failure(let error):
                    self.app.meetingPhase = .idle
                    self.notify("Meeting transcription failed", error.localizedDescription)
                }
            }
        }
    }

    /// Plain meeting transcript: mix the mic + call audio and transcribe as one
    /// block. Speaker separation is offered later, on demand. Runs synchronously —
    /// call off the main thread. Cleans up all temp audio.
    private func buildMeetingTranscript(sysURL: URL?, micURL: URL?,
                                        model: String) -> Result<String, Error> {
        let fm = FileManager.default
        defer { [sysURL, micURL].compactMap { $0 }.forEach { try? fm.removeItem(at: $0) } }

        let sources = [sysURL, micURL].compactMap { $0 }
        guard !sources.isEmpty else {
            return .failure(NSError(domain: "Voz", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No audio was recorded."]))
        }
        do {
            let mixed = try AudioConverter.mixToWav(sources)   // 16 kHz mono
            defer { try? fm.removeItem(at: mixed) }
            let segs = try self.transcriber.segments(wavURL: mixed, modelPath: model)
            return .success(Transcriber.formatSegments(segs))
        } catch {
            return .failure(error)
        }
    }

    /// Saves a finished meeting and kicks off local summary + follow-ups.
    private func saveAndAnalyzeMeeting(transcript: String, notes: String, model: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = trimmed.isEmpty ? "(no speech captured)" : trimmed
        app.meetingTranscript = finalText
        var entry = HistoryEntry(text: finalText, date: Date(), source: "Meeting",
                                 model: WhisperModels.friendlyName(model))
        entry.notes = notes.isEmpty ? nil : notes
        app.addMeeting(entry)
        app.meetingPhase = .done

        guard LocalLLM.shared.isReady && !trimmed.isEmpty else { return }
        app.meetingSummarizing = true
        LocalLLM.shared.summarizeMeeting(finalText) { [weak self] sres in
            guard let self = self else { return }
            self.app.meetingSummarizing = false
            if case .success(let s) = sres { self.app.setMeetingSummary(s, for: entry.id) }
        }
    }

    // MARK: - Notifications

    /// Mic access was refused. Once macOS has a "no" on record it never prompts
    /// again, so an alert saying "enable it in System Settings" leaves the user
    /// to navigate five levels of a pane they may never have opened. Open it for
    /// them instead, and say what to do once they're looking at it.
    private func handleMicDenied(_ access: AudioRecorder.MicAccess) {
        switch access {
        case .granted:
            return
        case .justDenied:
            // They chose Deny a second ago. Respect it; the Permissions screen
            // and Settings ▸ Updates are still there when they change their mind.
            notify("Microphone access denied",
                   "Voz can't dictate without it. You can grant it any time from Permissions…")
        case .previouslyDenied:
            SystemPermissions.openMicrophone()
            // If Voz isn't in that list, the pane is showing a stale snapshot --
            // System Settings does not live-refresh a Privacy list that was
            // already open, which is exactly the case here since we just opened
            // it. Say so, because otherwise the instruction is impossible to
            // follow and looks like the app is broken.
            notify("Turn on the microphone for Voz",
                   "System Settings is open at Privacy & Security → Microphone. "
                   + "Switch Voz on there, then press your shortcut again.\n\n"
                   + "Don't see Voz listed? Quit System Settings completely (⌘Q) and "
                   + "reopen it — the list doesn't refresh while it's already open.")
        }
    }

    private func notify(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
