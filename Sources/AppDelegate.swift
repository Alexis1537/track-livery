import AppKit
import UserNotifications
import Sparkle

/// Keeps the app in the Dock and routes files dropped on the Dock icon
/// (or opened via Finder) into the drop window.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, SPUUpdaterDelegate {
    private var dropWindow: DropWindow!
    /// Sparkle: checks GitHub for a newer signed version once a day and asks before installing.
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.migrateFromBeatportTag()
        buildMenu()
        // notifications: "new downloads found" carries an Import button (ruled 1 Nov 2026)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let importAction = UNNotificationAction(identifier: "IMPORT", title: "Import", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "NEW_DOWNLOADS", actions: [importAction],
                                                                 intentIdentifiers: [], options: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        dropWindow = DropWindow()
        dropWindow.show()
        _ = updater
        NSApp.activate(ignoringOtherApps: true)
    }

    // Called when a file is dropped on the Dock icon (CFBundleDocumentTypes in
    // Info.plist). Implementing only this one keeps it active alongside the
    // window's own drop zone.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        dropWindow.enqueue(path: filename)
        return true
    }

    /// Minimal menu bar: Settings… (⌘,), Hide, Quit (⌘Q), and Edit for text fields.
    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "About Track Livery", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        check.target = updater
        app.addItem(check)
        app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Track Livery", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Track Livery", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(.separator())
        let showItem = NSMenuItem(title: "Show Track Livery", action: #selector(showMainWindow), keyEquivalent: "0")
        showItem.target = self
        win.addItem(showItem)
        windowItem.submenu = win
        NSApp.mainMenu = main
    }

    @objc private func openSettings() { dropWindow.openSettings() }

    /// Never restart for an update in the middle of an import: wait until the queue is empty.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard dropWindow?.isBusy == true else { return false }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard self?.dropWindow?.isBusy != true else { return }
            timer.invalidate()
            installHandler()
        }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.categoryIdentifier == "NEW_DOWNLOADS" {
            DispatchQueue.main.async {
                if response.actionIdentifier == "IMPORT" { self.dropWindow.importFromNotification() }
                else { NSApp.activate(ignoringOtherApps: true) }
            }
        }
        completionHandler()
    }

    /// While the app is in front, the window itself shows new downloads; no banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    /// Clicking the Dock icon brings the window back after it was closed or minimised.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { dropWindow.show() }
        return true
    }

    @objc private func showMainWindow() { dropWindow.show() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // stay in the Dock, ready for the next drop
    }
}
