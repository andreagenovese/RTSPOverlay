import AppKit

/// Finestra con tutte le telecamere affiancate (stream secondario).
final class GridController: NSObject, NSWindowDelegate {
    var onOpenOverlay: ((Camera) -> Void)?
    var onClose: (() -> Void)?

    private let window: NSWindow
    private let grid = GridView()
    private var shownCameras: [Camera] = []
    private var shownPasswords: [String] = []

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "RTSP Overlay"
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.contentView = grid
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("grid")
    }

    func show() {
        reload(CameraStore.shared.cameras)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func reload(_ cameras: [Camera]) {
        let passwords = cameras.map { CameraStore.shared.password(for: $0.id) }
        guard cameras != shownCameras || passwords != shownPasswords else { return }
        shownCameras = cameras
        shownPasswords = passwords
        stopAll()
        for camera in cameras {
            let view = CameraView(camera: camera, quality: .sub)
            view.alwaysShowName = true
            view.onDoubleClick = { [weak self] in self?.onOpenOverlay?(camera) }
            grid.addSubview(view)
            view.start()
        }
        grid.needsLayout = true
    }

    func windowWillClose(_ notification: Notification) {
        stopAll()
        shownCameras = []
        shownPasswords = []
        onClose?()
    }

    private func stopAll() {
        for view in grid.subviews {
            (view as? CameraView)?.stop()
            view.removeFromSuperview()
        }
    }
}

final class GridView: NSView {
    override func layout() {
        super.layout()
        let n = subviews.count
        guard n > 0 else { return }
        let cols = Int(ceil(sqrt(Double(n))))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let w = bounds.width / CGFloat(cols)
        let h = bounds.height / CGFloat(rows)
        for (i, view) in subviews.enumerated() {
            let row = i / cols, col = i % cols
            view.frame = NSRect(x: CGFloat(col) * w, y: bounds.height - CGFloat(row + 1) * h, width: w, height: h)
                .insetBy(dx: 1, dy: 1)
        }
    }
}
