import AppKit
import ModelCore
import SwiftUI

@main
struct LocalModelLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = InventoryModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(model)
        } label: {
            Label("Modèles locaux", systemImage: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(before: .windowList) {
                Button("Fenêtre Modèles locaux") { AppWindows.showMain(model) }.keyboardShortcut("0", modifiers: .command)
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
        window.title = "Modèles locaux"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 860, height: 520)
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        window.setFrameAutosaveName("LocalModelLauncherMain")
        return window
    }
}
