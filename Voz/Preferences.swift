//
//  Preferences.swift
//  Voz
//
//  A small AppKit preferences window (built entirely in code — no storyboard):
//    • Trigger mode: Hotkey  vs  Double-tap Fn
//    • A "record shortcut" control to capture any key combo
//    • Paths to the whisper.cpp binary and model (with Browse… buttons)
//    • Play-sounds toggle
//
//  onChange() is called whenever something is saved so AppDelegate can
//  re-register the hotkey and refresh the menu.
//

import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

final class PreferencesWindowController: NSWindowController {
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Voz Preferences"
        window.center()
        super.init(window: window)
        window.contentViewController = PreferencesViewController(onChange: onChange)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class PreferencesViewController: NSViewController {
    private let onChange: () -> Void

    private let modePopup = NSPopUpButton()
    private let recorder = KeyRecorderControl()
    private let binaryField = NSTextField()
    private let modelPopup = NSPopUpButton()
    private let modelPathLabel = NSTextField(labelWithString: "")
    private let soundsCheckbox = NSButton(checkboxWithTitle: "Play start/stop sounds", target: nil, action: nil)
    private let startSoundPopup = NSPopUpButton()
    private let stopSoundPopup = NSPopUpButton()

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 450))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        loadValues()
    }

    // MARK: - UI construction

    private func buildUI() {
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 10

        // Trigger mode
        modePopup.addItems(withTitles: ["Hotkey", "Double-tap Fn key"])
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        grid.addRow(with: [label("Trigger:"), modePopup])

        // Shortcut recorder
        recorder.onCapture = { [weak self] hk in
            Settings.shared.hotKey = hk
            self?.onChange()
        }
        grid.addRow(with: [label("Shortcut:"), recorder])

        // Binary path
        binaryField.placeholderString = "~/whisper.cpp/build/bin/whisper-cli"
        binaryField.translatesAutoresizingMaskIntoConstraints = false
        binaryField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        grid.addRow(with: [label("whisper binary:"), hstack(binaryField, browseButton(#selector(browseBinary)))])

        // Model picker — lists every ggml-*.bin model found on disk so you can
        // switch models and compare. Selecting one applies it immediately.
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.translatesAutoresizingMaskIntoConstraints = false
        modelPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        grid.addRow(with: [label("Model:"), hstack(modelPopup, browseButton(#selector(browseModel)))])

        // Small caption under the picker showing the exact active model file.
        modelPathLabel.font = .systemFont(ofSize: 10)
        modelPathLabel.textColor = .secondaryLabelColor
        modelPathLabel.lineBreakMode = .byTruncatingMiddle
        modelPathLabel.translatesAutoresizingMaskIntoConstraints = false
        modelPathLabel.widthAnchor.constraint(equalToConstant: 300).isActive = true
        grid.addRow(with: [NSGridCell.emptyContentView, modelPathLabel])

        // Sounds — master toggle
        soundsCheckbox.target = self
        soundsCheckbox.action = #selector(saveTextFields)
        grid.addRow(with: [NSGridCell.emptyContentView, soundsCheckbox])

        // Sounds — Start sound picker + preview (changing it plays a preview)
        startSoundPopup.addItems(withTitles: Sound.available)
        startSoundPopup.target = self
        startSoundPopup.action = #selector(startSoundChanged)
        grid.addRow(with: [label("Start sound:"),
                           hstack(startSoundPopup, previewButton(#selector(previewStart)))])

        // Sounds — Stop sound picker + preview
        stopSoundPopup.addItems(withTitles: Sound.available)
        stopSoundPopup.target = self
        stopSoundPopup.action = #selector(stopSoundChanged)
        grid.addRow(with: [label("Stop sound:"),
                           hstack(stopSoundPopup, previewButton(#selector(previewStop)))])

        // Save button
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveTextFields))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let hint = label("Tip: Hotkey needs no permission. Fn double-tap needs Input Monitoring. Pasting needs Accessibility.")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 3
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(equalToConstant: 420).isActive = true

        view.addSubview(grid)
        view.addSubview(saveButton)
        view.addSubview(hint)
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hint.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            saveButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -12),
        ])
    }

    private func label(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        return l
    }

    private func hstack(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }

    private func browseButton(_ action: Selector) -> NSButton {
        NSButton(title: "Browse…", target: self, action: action)
    }

    private func previewButton(_ action: Selector) -> NSButton {
        let b = NSButton(title: "▶ Preview", target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    // MARK: - Load / save

    private func loadValues() {
        let s = Settings.shared
        modePopup.selectItem(at: s.triggerMode.rawValue)
        recorder.hotKey = s.hotKey
        binaryField.stringValue = s.binaryPath
        reloadModelPopup()
        soundsCheckbox.state = s.playSounds ? .on : .off
        startSoundPopup.selectItem(withTitle: s.startSound)
        stopSoundPopup.selectItem(withTitle: s.stopSound)
        recorder.isEnabled = (s.triggerMode == .hotKey)
    }

    @objc private func modeChanged() {
        let mode = TriggerMode(rawValue: modePopup.indexOfSelectedItem) ?? .hotKey
        Settings.shared.triggerMode = mode
        recorder.isEnabled = (mode == .hotKey)
        onChange()
    }

    @objc private func saveTextFields() {
        let s = Settings.shared
        s.binaryPath = binaryField.stringValue.trimmingCharacters(in: .whitespaces)
        s.playSounds = (soundsCheckbox.state == .on)
        onChange()
    }

    // MARK: - Model picker

    /// (Re)populates the model dropdown from the models found on disk and
    /// selects the currently-active one. Call this whenever the window opens so
    /// newly-downloaded models show up.
    private func reloadModelPopup() {
        modelPopup.removeAllItems()
        let models = WhisperModels.available
        for m in models {
            modelPopup.addItem(withTitle: m.name)
            modelPopup.lastItem?.representedObject = m.path
        }

        let current = Settings.shared.modelPath
        if let idx = models.firstIndex(where: { $0.path == current }) {
            modelPopup.selectItem(at: idx)
        } else if !current.isEmpty {
            // Active model isn't in the scanned folders (e.g. a custom path) —
            // show it at the top so the selection is accurate.
            modelPopup.insertItem(withTitle: WhisperModels.friendlyName(current), at: 0)
            modelPopup.item(at: 0)?.representedObject = current
            modelPopup.selectItem(at: 0)
        }

        // Trailing "Choose file…" escape hatch for a model anywhere on disk.
        modelPopup.menu?.addItem(.separator())
        modelPopup.addItem(withTitle: "Choose file…")

        updateModelPathLabel()
    }

    private func updateModelPathLabel() {
        modelPathLabel.stringValue = Settings.shared.modelPath
        modelPathLabel.toolTip = Settings.shared.modelPath
    }

    @objc private func modelChanged() {
        guard let item = modelPopup.selectedItem else { return }
        if item.title == "Choose file…" {
            browseModel()          // reselects the real value inside reloadModelPopup()
            reloadModelPopup()
            return
        }
        if let path = item.representedObject as? String {
            Settings.shared.modelPath = path
            updateModelPathLabel()
            onChange()
        }
    }

    // Changing a sound saves it AND plays it so you hear your choice immediately.
    @objc private func startSoundChanged() {
        let name = startSoundPopup.titleOfSelectedItem ?? "Tink"
        Settings.shared.startSound = name
        Sound.preview(name)
        onChange()
    }

    @objc private func stopSoundChanged() {
        let name = stopSoundPopup.titleOfSelectedItem ?? "Tink"
        Settings.shared.stopSound = name
        Sound.preview(name)
        onChange()
    }

    @objc private func previewStart() {
        Sound.preview(startSoundPopup.titleOfSelectedItem ?? "Tink")
    }

    @objc private func previewStop() {
        Sound.preview(stopSoundPopup.titleOfSelectedItem ?? "Tink")
    }

    @objc private func browseBinary() {
        pickFile(directoriesOnly: false) { [weak self] url in
            self?.binaryField.stringValue = url.path
            self?.saveTextFields()
        }
    }

    @objc private func browseModel() {
        pickFile(directoriesOnly: false, allowed: ["bin"]) { [weak self] url in
            Settings.shared.modelPath = url.path
            self?.reloadModelPopup()
            self?.onChange()
        }
    }

    private func pickFile(directoriesOnly: Bool, allowed: [String]? = nil,
                          completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directoriesOnly
        panel.canChooseDirectories = directoriesOnly
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true // whisper.cpp often lives in a dotfile-ish path
        if let allowed = allowed {
            panel.allowedContentTypes = allowed.compactMap { UTType(filenameExtension: $0) }
        }
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }
}

// MARK: - Key recorder control

/// A button-like control that captures the next key combo you press.
final class KeyRecorderControl: NSButton {
    var onCapture: ((HotKey) -> Void)?
    var hotKey: HotKey = HotKey.defaultHotKey { didSet { updateTitle() } }

    private var recording = false {
        didSet { updateTitle() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }

    private func commonInit() {
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        updateTitle()
    }

    private func updateTitle() {
        title = recording ? "Press keys… (Esc to cancel)" : hotKey.displayString
    }

    @objc private func beginRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }

        // Esc cancels.
        if event.keyCode == UInt16(kVK_Escape) {
            recording = false
            return
        }

        let mods = HotKey.carbonModifiers(from: event.modifierFlags)
        // Require at least one modifier (avoids capturing a bare letter that
        // would then fire constantly). Function keys are allowed bare.
        let isFunctionKey = HotKey.isFunctionKey(event.keyCode)
        guard mods != 0 || isFunctionKey else {
            NSSound.beep()
            return
        }

        let hk = HotKey(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
        hotKey = hk
        recording = false
        onCapture?(hk)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }
}
