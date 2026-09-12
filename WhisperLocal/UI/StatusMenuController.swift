import AppKit
import Combine
import os
import SwiftUI

/// The menu bar item as a real `NSMenu`, on both channels.
///
/// The reason it exists: in a full-screen Space the menu bar hides until the mouse
/// reaches the top, and the system only holds it down while a *menu* is open. The
/// SwiftUI panel is a window pinned to the icon, so the bar hid as soon as the
/// mouse moved away and took the panel with it. A menu stays until you dismiss it,
/// which is what every other menu bar item does.
///
/// The header keeps the panel's typography by hosting the same `MenuBarHeader`
/// view; every row is a native item, so highlighting, keyboard navigation, key
/// equivalents, and dismissal are the system's rather than imitations of it.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    static let shared = StatusMenuController()

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var observers: Set<AnyCancellable> = []
    /// Onboarding is surfaced when the menu closes, not while it is open —
    /// activating the app to raise a window mid-tracking can cancel the menu.
    private var onboardingPendingOnClose = false
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "menu")

    private var controller: DictationController { .shared }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.setAccessibilityLabel(AppIdentity.productName)
        // ⌘-dragging the item out of the menu bar quits, which is what the app has
        // always done and the one gesture the SwiftUI item handled for us. Without
        // this the item simply refuses to move; with `.removalAllowed` and no
        // observer it would vanish and leave the app running with the hotkey live
        // and no way back to Settings or Quit.
        item.behavior = .removalAllowed
        removalObservation = item.observe(\.isVisible, options: [.new]) { item, _ in
            guard !item.isVisible else { return }
            Task { @MainActor in
                MenuBarRemoval.quit()
                // Reached only when the user cancelled the quit to keep a take.
                // The item is already gone by then, so put it back rather than
                // leaving them with no menu bar at all.
                item.isVisible = true
            }
        }
        statusItem = item
        observeState()
        updateButton()
    }

    private var removalObservation: NSKeyValueObservation?

    // MARK: - Icon

    private func observeState() {
        // `objectWillChange` fires before the value moves, so read on the next turn.
        // The main queue drains in every run loop mode, including menu tracking.
        let changes: [ObservableObjectPublisher] = [
            controller.objectWillChange,
            controller.permissions.objectWillChange,
            controller.transcription.objectWillChange
        ]
        Publishers.MergeMany(changes.map { $0.eraseToAnyPublisher() })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &observers)
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        let symbol = MenuBarIcon.symbol(for: controller)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: AppIdentity.productName)
        image?.isTemplate = true
        button.image = image
        if AppIdentity.isDevBuild {
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(
                string: " " + AppIdentity.versionSummary,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)]
            )
        } else {
            button.imagePosition = .imageOnly
            button.title = ""
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        // Same as the panel's onAppear: the hotkey is (re)armed whenever the menu
        // is looked at, and a missing permission is surfaced.
        controller.start()
        onboardingPendingOnClose = controller.showOnboarding
    }

    func menuDidClose(_ menu: NSMenu) {
        guard onboardingPendingOnClose else { return }
        onboardingPendingOnClose = false
        WindowOpener.shared.open(title: "Welcome", id: "onboarding")
    }

    /// Rebuilt on every open, so it always describes the moment it was opened.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(headerItem())
        menu.addItem(.separator())

        if let line = controller.sessionContextLine {
            menu.addItem(NSMenuItem.sectionHeader(title: "Session Context"))
            menu.addItem(detailItem(line))
            menu.addItem(ActionItem("Edit Context…") {
                WindowOpener.shared.open(title: "Session context", id: "session-context")
            })
            if controller.hasActiveSessionContext {
                menu.addItem(ActionItem("Clear Context") { [weak self] in
                    self?.controller.clearSessionContext()
                })
            }
            menu.addItem(.separator())
        }

        let updater = AppUpdater.shared
        let update = ActionItem(updater.menuTitle) {
            Task { await updater.handleMenuClick() }
        }
        update.isEnabled = !(updater.isBusy && !AppIdentity.isDevBuild)
        menu.addItem(update)
        menu.addItem(.separator())

        menu.addItem(ActionItem("Settings…", key: ",") { [weak self] in
            WindowOpener.shared.open(title: AppIdentity.settingsWindowTitle, id: "settings")
            self?.controller.showSettings = true
        })
        menu.addItem(ActionItem("Dictation Log…") {
            WindowOpener.shared.open(title: "Dictation Log", id: "log")
        })
        menu.addItem(ActionItem("Permissions / Onboarding…") { [weak self] in
            WindowOpener.shared.open(title: "Welcome", id: "onboarding")
            self?.controller.showOnboarding = true
        })
        menu.addItem(.separator())

        menu.addItem(microphoneItem())
        menu.addItem(.separator())

        // Only when it can help. A reload is a repair, and it was the one repair
        // action in a menu of nine — shown to everyone, useful in one state. A
        // failed load does not retry itself, so the affordance has to exist; it
        // just does not have to be there when the model is fine. The menu is
        // rebuilt on every open, so this is correct each time.
        if !controller.transcription.isReady {
            menu.addItem(ActionItem("Retry loading \(controller.settings.asrModel.shortName)") { [weak self] in
                guard let self else { return }
                Task {
                    await self.controller.transcription.ensureModel(
                        named: self.controller.settings.asrModel, force: true
                    )
                }
            })
            menu.addItem(.separator())
        }

        // Straight to terminate so the app delegate can ask about work in flight.
        menu.addItem(ActionItem("Quit \(AppIdentity.productName)", key: "q") {
            NSApplication.shared.terminate(nil)
        })
    }

    /// Same header view as the panel, hosted in a custom item. Only this row is
    /// custom — a menu's own rows cannot carry a bold title with a trailing value
    /// or an orange warning line.
    private func headerItem() -> NSMenuItem {
        let host = NSHostingView(rootView: HeaderHost(controller: controller))
        host.frame.size = host.fittingSize
        let item = NSMenuItem()
        item.view = host
        return item
    }

    /// The session context can run to 280 characters, and a menu row does not
    /// wrap — as a plain item it would stretch the menu across the screen.
    private func detailItem(_ text: String) -> NSMenuItem {
        let host = NSHostingView(rootView:
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: Self.contentWidth - Self.nativeInsetCorrection, alignment: .leading)
                .padding(.leading, 14 + Self.nativeInsetCorrection)
                .padding(.trailing, 14)
                .padding(.bottom, 4)
        )
        host.frame.size = host.fittingSize
        let item = NSMenuItem()
        item.view = host
        return item
    }

    /// Matches the panel's width so wrapped lines break in the same places.
    static let contentWidth: CGFloat = 264
    /// A menu insets its own rows 2pt further than the panel's 14pt padding, so the
    /// hosted rows sat visibly left of the native ones beneath them. Measured from
    /// a rendered menu: header text at 22.5pt, native text at 25pt. The trailing
    /// edge already matched to the pixel (version and ⌘Q both end at 284pt), so
    /// only the leading side moves.
    static let nativeInsetCorrection: CGFloat = 2
}

/// Wraps the shared header and re-captures `openWindow` on every open. The launch
/// capture is the one relied on; this is the backstop if it ever missed.
private struct HeaderHost: View {
    @ObservedObject var controller: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarHeader(controller: controller)
            .padding(.leading, StatusMenuController.nativeInsetCorrection)
            .frame(width: StatusMenuController.contentWidth + 28, alignment: .leading)
            .padding(.top, 2)
            .onAppear { WindowOpener.shared.capture(openWindow) }
    }
}

extension StatusMenuController {
    /// The same microphone list the HUD chip opens, reachable between takes.
    @MainActor
    fileprivate func microphoneItem() -> NSMenuItem {
        let devices = AudioInputSelection.inputDevices()
        let chosen = SettingsStore.shared.preferredInputDeviceUID
        let parent = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, entry) in InputMenu.items(devices: devices, chosenUID: chosen).enumerated() {
            if index == 1 { submenu.addItem(.separator()) }
            guard entry.isEnabled else {
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                submenu.addItem(item)
                continue
            }
            let uid = entry.uid
            let item = ActionItem(entry.title) { [weak self] in
                self?.controller.recorder.useInput(uid: uid)
            }
            item.state = entry.isChecked ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }
}

/// A menu item that runs a closure. Target/action is all `NSMenuItem` offers.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        if !key.isEmpty { keyEquivalentModifierMask = .command }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

/// Opens SwiftUI `Window` scenes from AppKit.
///
/// `openWindow` is only handed out through a view's environment, and a menu's
/// actions are not views. It was measured before relying on it: an action captured
/// from a hosting view outside any scene opens `Window` scenes, keeps working
/// after that view is thrown away, and reopens a window after it is closed.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()

    private var action: OpenWindowAction?
    private var captureWindow: NSWindow?
    private let logger = Logger(subsystem: "com.usingcolor.WhisperLocal", category: "menu")

    func capture(_ action: OpenWindowAction) {
        self.action = action
    }

    /// Captured at launch rather than on the menu's first open: a hosting view in
    /// a menu may not see `onAppear` until tracking ends, which is after the click
    /// that needed the action.
    func captureAtLaunch() {
        guard action == nil, captureWindow == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CaptureView { [weak self] action in
            guard let self else { return }
            self.capture(action)
            self.logger.info("openWindow captured at launch")
            // Done with the host; the action outlives it, including a close().
            // Ordering it out alone left it in the window server's list.
            DispatchQueue.main.async {
                self.captureWindow?.contentView = nil
                self.captureWindow?.close()
                self.captureWindow = nil
            }
        })
        window.orderFrontRegardless()
        captureWindow = window
    }

    func open(title: String, id: String) {
        guard let action else {
            logger.error("openWindow not captured; cannot open \(id, privacy: .public)")
            return
        }
        AppWindowFocus.present(title: title) { action(id: id) }
    }
}

private struct CaptureView: View {
    let onCapture: (OpenWindowAction) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear { onCapture(openWindow) }
    }
}
