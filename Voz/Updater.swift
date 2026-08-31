//
//  Updater.swift  —  open-source build
//
//  The paid build of Voz ships a Sparkle updater: it checks a signed appcast,
//  verifies an EdDSA signature against a key compiled into the app, and installs
//  in place. None of that is in this repo, on purpose:
//
//    * The signing key is what makes an update trustworthy. Publishing it, or
//      the private feed it authenticates against, would let anyone push code to
//      every installed copy. So the key stays out, and with it the updater.
//    * A source build already has a better update mechanism than an appcast:
//      `git pull` and hit Run. You are the one deciding what code you execute,
//      which is the whole reason to build it yourself.
//
//  This file keeps the same shape the UI expects, so nothing else had to change,
//  and reports honestly that this build does not update itself. The practical
//  effect is that the open-source Voz makes *no* network requests at all — not
//  even the once-a-day version check the paid build makes.
//
//  If you would rather it just updated itself, that is what the $2.99 buys:
//  https://www.vozwhisper.com
//

import Foundation
import Combine
import AppKit

/// Where to send someone who clicks "Check Now". Change this if you fork.
let vozRepositoryURL = URL(string: "https://github.com/quietbin/voz-mac")!

struct AvailableUpdate: Equatable {
    let version: String
    let build: String
}

enum UpdatePhase: Equatable {
    case idle
    case downloading(fraction: Double?)
    case extracting(fraction: Double)
    case readyToRelaunch
    case stagedForNextLaunch(version: String)
    case installing
    case failed(String)
}

/// A no-op stand-in for the Sparkle-backed updater in the paid build.
///
/// Every property the UI reads is here and stays constant: there is no feed to
/// poll, so nothing can ever change. `checkForUpdates` opens the repository
/// instead of phoning home.
final class Updater: ObservableObject {

    static let shared = Updater()

    /// Always false, and setting it does nothing. A source build has no feed to
    /// check, and pretending otherwise would be the one lie this app cannot
    /// afford — the whole claim is that nothing leaves your Mac.
    @Published var automaticallyChecksForUpdates: Bool = false {
        didSet { if automaticallyChecksForUpdates { automaticallyChecksForUpdates = false } }
    }

    @Published var installsAutomatically: Bool = false {
        didSet { if installsAutomatically { installsAutomatically = false } }
    }

    /// True so "Check Now" stays clickable — it opens the repo rather than a feed.
    @Published private(set) var canCheckForUpdates = true

    @Published private(set) var availableUpdate: AvailableUpdate? = nil
    @Published private(set) var pendingBuildDisplay: String? = nil
    @Published private(set) var isChecking = false

    /// Non-nil so the status dot reads as settled rather than mid-check.
    @Published private(set) var lastChecked: Date? = Date()

    /// The status pill renders `.failed`'s string verbatim, which is the one
    /// slot available for saying what this build actually is.
    @Published private(set) var phase: UpdatePhase = .failed("Source build — git pull to update")

    var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var currentVersion: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(shortVersion) (\(build)) · source"
    }

    // MARK: - Actions, all inert except the one that opens a browser

    func checkQuietly() {}
    func dismissAvailableUpdate() {}
    func restoreAvailableUpdate() {}
    func installAvailableUpdate() {}
    func relaunchNow() {}
    func installOnNextQuit() {}

    @objc func checkForUpdates(_ sender: Any?) {
        NSWorkspace.shared.open(vozRepositoryURL)
    }
}
