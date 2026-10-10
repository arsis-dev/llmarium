import AppKit
import ModelCore
import SwiftUI

@main
struct LLMariumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = InventoryModel.shared

    init() { Self.migrateDefaults() }

    /// Preferences saved under the bundle id used before the app was named LLMarium, copied once.
    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedLegacyDefaults") else { return }
        if let legacy = UserDefaults(suiteName: "dev.arsis.localmodellauncher") {
            for key in ["proxyEnabled", "section", "lastProjectFolder", "hasShownMainWindow"] where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
            }
            if let frame = legacy.string(forKey: "NSWindow Frame LocalModelLauncherMain"), defaults.object(forKey: "NSWindow Frame LLMariumMain") == nil {
                defaults.set(frame, forKey: "NSWindow Frame LLMariumMain")
            }
        }
        defaults.set(true, forKey: "migratedLegacyDefaults")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            Label("LLMarium", systemImage: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(before: .windowList) {
                Button("Fenêtre LLMarium") { AppWindows.showMain(model) }.keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await InventoryModel.shared.refresh() }
        ProxyController.shared.startIfEnabled()
        if !UserDefaults.standard.bool(forKey: "hasShownMainWindow") {
            AppWindows.showMain(InventoryModel.shared)
            UserDefaults.standard.set(true, forKey: "hasShownMainWindow")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindows.showMain(InventoryModel.shared)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// One main window besides the menu bar panel, as in Appothèque.
@MainActor
enum AppWindows {
    private static var main: NSWindow?

    static func showMain(_ model: InventoryModel, section: Section? = nil) {
        if main == nil { main = makeMainWindow(model) }
        if let section { model.section = section }
        main?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        Task { await model.refresh() }
    }

    private static func makeMainWindow(_ model: InventoryModel) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let controller = NSHostingController(rootView: MainWindowView().environmentObject(model))
        // The window keeps the app name as title; the section name is shown in the toolbar.
        controller.sceneBridgingOptions = [.toolbars]
        window.contentViewController = controller
        window.title = "LLMarium"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 860, height: 520)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        window.setFrameAutosaveName("LLMariumMain")
        return window
    }
}
