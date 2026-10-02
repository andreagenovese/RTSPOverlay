import AppKit
import AVFoundation

/// Vista che mostra il live di una telecamera e gestisce connessione e riconnessione automatica.
final class CameraView: NSView {
    private(set) var camera: Camera
    private(set) var quality: StreamQuality

    var onVideoSize: ((CGSize) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var alwaysShowName = false { didSet { updateNameVisibility() } }

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let videoView = NSView()
    private let renderer: VideoRenderer
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let queue = DispatchQueue(label: "rtspoverlay.stream", qos: .userInteractive)
    private var client: RTSPClient?
    private var retryWork: DispatchWorkItem?
    private var running = false
    private var hovering = false
    private var trackingArea: NSTrackingArea?

    init(camera: Camera, quality: StreamQuality) {
        self.camera = camera
        self.quality = quality
        renderer = VideoRenderer(layer: displayLayer)
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 270))

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        videoView.layer = displayLayer
        videoView.wantsLayer = true
        videoView.frame = bounds
        videoView.autoresizingMask = [.width, .height]
        addSubview(videoView)

        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        for label in [nameLabel, statusLabel] {
            label.textColor = .white
            label.shadow = shadow
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 4

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])

        renderer.onVideoSize = { [weak self] size in self?.onVideoSize?(size) }
        renderer.onFirstFrame = { [weak self] in self?.setStatus(nil) }
        nameLabel.stringValue = camera.name
        updateNameVisibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - Stream

    func start() {
        guard !running else { return }
        running = true
        connect()
    }

    func stop() {
        running = false
        retryWork?.cancel()
        retryWork = nil
        client?.stop()
        client = nil
    }

    func update(camera: Camera) {
        self.camera = camera
        nameLabel.stringValue = camera.name
        restart()
    }

    func setQuality(_ quality: StreamQuality) {
        self.quality = quality
        restart()
    }

    func restart() {
        guard running else { return }
        stop()
        start()
    }

    private func connect() {
        guard running else { return }
        retryWork = nil
        guard !camera.host.trimmed.isEmpty else {
            return setStatus(String(localized: "Address not set.\nOpen Settings from the menu bar."))
        }
        let password = CameraStore.shared.password(for: camera.id)
        guard let c = RTSPClient(url: camera.url(for: quality), username: camera.username, password: password, queue: queue) else {
            return setStatus(String(localized: "Invalid address"))
        }
        let renderer = self.renderer
        c.onStreamStart = { codec, sets in renderer.reset(codec: codec, parameterSets: sets) }
        c.onAccessUnit = { nals, complete in renderer.render(nals, complete: complete) }
        c.onState = { [weak self, weak c] state in
            DispatchQueue.main.async {
                guard let self, let c, self.client === c else { return }
                self.handle(state)
            }
        }
        client = c
        c.start()
    }

    private func handle(_ state: RTSPClient.State) {
        switch state {
        case .connecting:
            setStatus(String(localized: "Connecting to \(camera.host)…"))
        case .playing:
            setStatus(String(localized: "Waiting for video…"))
        case .failed(let message):
            client = nil
            setStatus(String(localized: "\(message)\nRetrying in 5 seconds…"))
            let work = DispatchWorkItem { [weak self] in self?.connect() }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    private func setStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
    }

    // MARK: - Mouse

    private func updateNameVisibility() {
        nameLabel.isHidden = !(alwaysShowName || hovering)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateNameVisibility()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateNameVisibility()
        onHover?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
