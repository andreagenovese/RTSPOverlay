import SwiftUI
import CoreMedia

struct SettingsView: View {
    @ObservedObject private var store = CameraStore.shared
    @State private var selection: UUID?
    var onOpen: (UUID) -> Void

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.cameras) { camera in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(camera.name)
                            Text(camera.host.isEmpty ? "—" : String(localized: "\(camera.host) · channel \(camera.channel)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(camera.id)
                    }
                    .onMove { store.cameras.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack(spacing: 2) {
                    Button(action: add) { Image(systemName: "plus").frame(width: 20, height: 20) }
                        .help("Add camera")
                    Button(action: remove) { Image(systemName: "minus").frame(width: 20, height: 20) }
                        .help("Remove camera")
                        .disabled(selection == nil)
                    Button(action: duplicateNextChannel) { Image(systemName: "plus.square.on.square").frame(width: 20, height: 20) }
                        .help("Duplicate on the next channel (handy for NVRs)")
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)

            Group {
                if let id = selection, let binding = binding(for: id) {
                    CameraForm(camera: binding, onOpen: { onOpen(id) }).id(id)
                } else {
                    (store.cameras.isEmpty ? Text("Add a camera with the + button") : Text("Select a camera"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 440)
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { if selection == nil { selection = store.cameras.first?.id } }
    }

    private func binding(for id: UUID) -> Binding<Camera>? {
        guard let camera = store.camera(id) else { return nil }
        return Binding(get: { store.camera(id) ?? camera }, set: { store.update($0) })
    }

    private func add() {
        let camera = Camera()
        store.add(camera)
        selection = camera.id
    }

    private func remove() {
        guard let id = selection else { return }
        selection = nil
        store.remove(id)
    }

    private func duplicateNextChannel() {
        guard let id = selection, let source = store.camera(id) else { return }
        var copy = source
        copy.id = UUID()
        copy.channel = source.channel + 1
        copy.name = source.name.replacingOccurrences(of: #"\s*CH\d+$"#, with: "", options: .regularExpression)
            + " CH\(copy.channel)"
        store.add(copy)
        store.setPassword(store.password(for: id), for: copy.id)
        selection = copy.id
    }
}

private struct CameraForm: View {
    @Binding var camera: Camera
    var onOpen: () -> Void

    @ObservedObject private var store = CameraStore.shared
    @State private var password = ""
    @State private var tester: ConnectionTester?
    @State private var testResult: String?

    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $camera.name)
            }
            Section("Connection") {
                TextField("IP address or host", text: $camera.host, prompt: Text("192.168.1.100 or myhome.ddns.net"))
                TextField("RTSP port", value: $camera.port, format: .number.grouping(.never))
                TextField("Username", text: $camera.username)
                SecureField("Password", text: $password)
                    .onChange(of: password) { _, value in store.setPassword(value, for: camera.id) }
            }
            Section {
                Stepper(value: $camera.channel, in: 1...128) { Text("Channel: \(camera.channel)") }
                Picker("Default stream", selection: $camera.quality) {
                    ForEach(StreamQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                TextField("Custom path", text: $camera.customPath, prompt: Text("empty = /Streaming/Channels/…"))
                LabeledContent("URL") {
                    Text(camera.url(for: camera.quality))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Stream")
            } footer: {
                Text("Camera connected directly: channel 1. With an NVR, the channel is the camera's input number. The sub stream is recommended for overlays: it is very light.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button(tester == nil ? String(localized: "Test connection") : String(localized: "Testing…"), action: test)
                        .disabled(tester != nil || camera.host.trimmed.isEmpty)
                    Button("Open as overlay", action: onOpen)
                        .disabled(camera.host.trimmed.isEmpty)
                    Spacer()
                }
                if let testResult {
                    Text(testResult).font(.callout).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { password = store.password(for: camera.id) }
    }

    private func test() {
        testResult = nil
        let t = ConnectionTester()
        tester = t
        t.run(camera: camera, password: password) { result in
            testResult = result
            tester = nil
        }
    }
}

/// Si collega, attende il primo fotogramma decodificabile e riporta codec e risoluzione.
final class ConnectionTester {
    private let queue = DispatchQueue(label: "rtspoverlay.tester")
    private var client: RTSPClient?
    private var done = false

    func run(camera: Camera, password: String, completion: @escaping (String) -> Void) {
        let finish: (String) -> Void = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, !self.done else { return }
                self.done = true
                self.client?.stop()
                self.client = nil
                completion(message)
            }
        }
        guard let c = RTSPClient(url: camera.url(for: camera.quality), username: camera.username,
                                 password: password, queue: queue) else {
            return finish("❌ " + String(localized: "Invalid address"))
        }
        let renderer = VideoRenderer(layer: nil)
        var codec = VideoCodec.h264
        c.onStreamStart = { streamCodec, sets in
            codec = streamCodec
            renderer.reset(codec: streamCodec, parameterSets: sets)
        }
        c.onAccessUnit = { nals, complete in
            guard renderer.makeSampleBuffer(nals, complete: complete) != nil, let format = renderer.formatDescription else { return }
            let d = CMVideoFormatDescriptionGetDimensions(format)
            finish("✅ " + String(localized: "Connected: \(codec.rawValue) \(Int(d.width))×\(Int(d.height))"))
        }
        c.onState = { state in
            if case .failed(let message) = state { finish("❌ \(message)") }
        }
        client = c
        c.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish("❌ " + String(localized: "Timeout: no frames received")) }
    }
}
