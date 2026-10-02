import AppKit

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Finestra flottante con il live di una telecamera.
final class OverlayController: NSObject, NSWindowDelegate {
    private static var cascade = 0

    private(set) var camera: Camera
    private(set) var clickThrough = false
    var onClose: ((OverlayController) -> Void)?

    private var password: String
    private var prefs: OverlayPrefs
    private let panel: OverlayPanel
    private let cameraView: CameraView

    init(camera: Camera) {
        self.camera = camera
        password = CameraStore.shared.password(for: camera.id)
        prefs = OverlayPrefs.load(camera.id)
        cameraView = CameraView(camera: camera, quality: prefs.quality ?? camera.quality)
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        super.init()

        panel.title = camera.name
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .black
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 160, height: 90)
        panel.delegate = self
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentView = cameraView

        cameraView.onHover = { [weak self] inside in self?.panel.standardWindowButton(.closeButton)?.isHidden = !inside }
        cameraView.onVideoSize = { [weak self] size in self?.applyAspectRatio(size) }
        cameraView.onDoubleClick = { [weak self] in self?.toggleQuality() }
        cameraView.menuProvider = { [weak self] in self?.makeMenu() }

        applyPrefs()
        let autosaveName = "overlay-\(camera.id.uuidString)"
        if !panel.setFrameUsingName(autosaveName) { placeDefault() }
        panel.setFrameAutosaveName(autosaveName)
    }

    func show() {
        panel.orderFrontRegardless()
        cameraView.start()
    }

    func close() { panel.close() }

    func update(camera newCamera: Camera, password newPassword: String) {
        guard newCamera != camera || newPassword != password else { return }
        camera = newCamera
        password = newPassword
        panel.title = newCamera.name
        cameraView.update(camera: newCamera)
    }

    func setClickThrough(_ enabled: Bool) {
        clickThrough = enabled
        panel.ignoresMouseEvents = enabled
    }

    func windowWillClose(_ notification: Notification) {
        cameraView.stop()
        onClose?(self)
    }

    // MARK: - Layout

    private func placeDefault() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let offset = CGFloat(Self.cascade % 6) * 30
        Self.cascade += 1
        panel.setFrame(NSRect(x: screen.maxX - 480 - 20 - offset, y: screen.maxY - 270 - 20 - offset,
                              width: 480, height: 270), display: false)
    }

    private func applyAspectRatio(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        panel.contentAspectRatio = size
        var frame = panel.frame
        let height = (frame.width * size.height / size.width).rounded()
        guard abs(height - frame.height) > 1 else { return }
        frame.origin.y += frame.height - height // mantiene fermo il bordo superiore
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func applyPrefs() {
        panel.alphaValue = prefs.opacity
        panel.level = prefs.alwaysOnTop ? .floating : .normal
    }

    // MARK: - Menu contestuale

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(String(localized: "High quality (main stream)"), #selector(toggleQuality), on: cameraView.quality == .main))
        menu.addItem(item(String(localized: "Always on top"), #selector(toggleOnTop), on: prefs.alwaysOnTop))

        let opacity = NSMenuItem(title: String(localized: "Opacity"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for value in [100, 85, 70, 50, 30] {
            let i = item("\(value)%", #selector(setOpacity(_:)), on: Int((prefs.opacity * 100).rounded()) == value)
            i.tag = value
            sub.addItem(i)
        }
        opacity.submenu = sub
        menu.addItem(opacity)
        menu.addItem(item(String(localized: "Ignore clicks (re-enable from the menu bar)"), #selector(enableClickThrough)))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Reconnect"), #selector(reconnect)))
        menu.addItem(item(String(localized: "Close"), #selector(closeFromMenu)))
        return menu
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    @objc private func toggleQuality() {
        let quality: StreamQuality = cameraView.quality == .main ? .sub : .main
        prefs.quality = quality
        prefs.save(camera.id)
        cameraView.setQuality(quality)
    }

    @objc private func toggleOnTop() {
        prefs.alwaysOnTop.toggle()
        prefs.save(camera.id)
        applyPrefs()
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        prefs.opacity = Double(sender.tag) / 100
        prefs.save(camera.id)
        applyPrefs()
    }

    @objc private func enableClickThrough() { setClickThrough(true) }

    @objc private func reconnect() { cameraView.restart() }

    @objc private func closeFromMenu() { close() }
}
