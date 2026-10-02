import AppKit
import SwiftUI
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = CameraStore.shared
    private let openOverlaysKey = "openOverlays"
    private var statusItem: NSStatusItem!
    private var overlays: [UUID: OverlayController] = [:]
    private var grid: GridController?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "RTSP Overlay")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Applica le modifiche delle impostazioni alle finestre aperte (con un piccolo ritardo mentre si digita)
        store.$cameras.combineLatest(store.$passwords)
            .dropFirst()
            .debounce(for: .milliseconds(800), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.syncWithStore() }
            .store(in: &cancellables)

        let ids = (UserDefaults.standard.stringArray(forKey: openOverlaysKey) ?? []).compactMap(UUID.init)
        for id in ids {
            if let camera = store.camera(id) { openOverlay(camera, persist: false) }
        }
        if store.cameras.isEmpty { showSettings() }
    }

    // MARK: - Menu nella barra

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if store.cameras.isEmpty {
            let empty = NSMenuItem(title: String(localized: "No cameras configured"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for camera in store.cameras {
            let item = NSMenuItem(title: camera.name, action: #selector(toggleOverlay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = camera.id
            item.state = overlays[camera.id] != nil ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        if !store.cameras.isEmpty {
            menu.addItem(item(String(localized: "Open all as overlays"), #selector(openAll)))
            menu.addItem(item(String(localized: "Close all overlays"), #selector(closeAll)))
            menu.addItem(item(String(localized: "Grid with all cameras"), #selector(showGrid)))
        }
        if overlays.values.contains(where: \.clickThrough) {
            menu.addItem(item(String(localized: "Re-enable clicks on overlays"), #selector(restoreClicks)))
        }
        menu.addItem(.separator())
        let login = item(String(localized: "Launch at Login"), #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item(String(localized: "Settings…"), #selector(showSettings), key: ","))
        menu.addItem(item(String(localized: "Quit"), #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    @objc private func toggleOverlay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        if let overlay = overlays[id] {
            overlay.close()
        } else if let camera = store.camera(id) {
            openOverlay(camera)
        }
    }

    @objc private func openAll() { store.cameras.forEach { openOverlay($0) } }

    @objc private func closeAll() { overlays.values.forEach { $0.close() } }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "Could not change the login item")
            NSApp.activate()
            alert.runModal()
        }
        // Se macOS richiede l'approvazione dell'utente, apre Impostazioni di Sistema > Elementi login
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func restoreClicks() { overlays.values.forEach { $0.setClickThrough(false) } }

    @objc private func showGrid() {
        if grid == nil {
            let g = GridController()
            g.onOpenOverlay = { [weak self] camera in self?.openOverlay(camera) }
            g.onClose = { [weak self] in self?.grid = nil }
            grid = g
        }
        grid?.show()
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = String(localized: "RTSP Overlay – Settings")
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView(onOpen: { [weak self] id in
                guard let self, let camera = self.store.camera(id) else { return }
                self.openOverlay(camera)
            }))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Overlay

    private func openOverlay(_ camera: Camera, persist: Bool = true) {
        if let existing = overlays[camera.id] {
            existing.show()
            return
        }
        let overlay = OverlayController(camera: camera)
        overlay.onClose = { [weak self] closed in
            self?.overlays[closed.camera.id] = nil
            self?.saveOpenOverlays()
        }
        overlays[camera.id] = overlay
        overlay.show()
        if persist { saveOpenOverlays() }
    }

    private func saveOpenOverlays() {
        UserDefaults.standard.set(overlays.keys.map(\.uuidString), forKey: openOverlaysKey)
    }

    private func syncWithStore() {
        for (id, overlay) in overlays {
            if let camera = store.camera(id) {
                overlay.update(camera: camera, password: store.password(for: id))
            } else {
                overlay.close()
            }
        }
        grid?.reload(store.cameras)
    }

    // MARK: - Menu principale (serve per Cmd+C/V/X/A nei campi di testo)

    private func buildMainMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem()
            let sub = NSMenu(title: title)
            items.forEach { sub.addItem($0) }
            top.submenu = sub
            main.addItem(top)
        }
        add("RTSP Overlay", [
            item(String(localized: "Settings…"), #selector(showSettings), key: ","),
            .separator(),
            NSMenuItem(title: String(localized: "Quit RTSP Overlay"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])
        add(String(localized: "Edit"), [
            NSMenuItem(title: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z"),
            NSMenuItem(title: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z"),
            .separator(),
            NSMenuItem(title: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        add(String(localized: "Window"), [
            NSMenuItem(title: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ])
        NSApp.mainMenu = main
    }
}
