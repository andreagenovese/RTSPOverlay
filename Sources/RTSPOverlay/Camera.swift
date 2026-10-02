import Foundation
import Combine
import Security

enum StreamQuality: String, Codable, CaseIterable {
    case main, sub

    var label: String { self == .main ? String(localized: "Main (high quality)") : String(localized: "Sub (lightweight)") }
}

struct Camera: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = String(localized: "New camera")
    var host = ""
    var port = 554
    var username = "admin"
    var channel = 1
    var quality: StreamQuality = .sub
    /// Percorso RTSP alternativo; vuoto = schema predefinito /Streaming/Channels/<canale>0<1|2>.
    var customPath = ""

    func path(for quality: StreamQuality) -> String {
        let custom = customPath.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom.hasPrefix("/") ? custom : "/" + custom }
        // Canale 1 → 101 (principale) / 102 (secondario), canale 12 → 1201 / 1202
        return "/Streaming/Channels/\(channel)0\(quality == .main ? 1 : 2)"
    }

    func url(for quality: StreamQuality) -> String {
        let h = host.trimmingCharacters(in: .whitespaces)
        let hostPart = h.contains(":") ? "[\(h)]" : h
        return "rtsp://\(hostPart):\(port)\(path(for: quality))"
    }
}

final class CameraStore: ObservableObject {
    static let shared = CameraStore()

    @Published var cameras: [Camera] = [] { didSet { saveCameras() } }
    @Published private(set) var passwords: [UUID: String] = [:]

    private let camerasKey = "cameras"

    private init() {
        if let data = UserDefaults.standard.data(forKey: camerasKey),
           let list = try? JSONDecoder().decode([Camera].self, from: data) {
            cameras = list
        }
        if let data = Keychain.read(),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            passwords = Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        }
    }

    func camera(_ id: UUID) -> Camera? { cameras.first { $0.id == id } }

    func password(for id: UUID) -> String { passwords[id] ?? "" }

    func setPassword(_ password: String, for id: UUID) {
        guard passwords[id] != password else { return }
        passwords[id] = password
        savePasswords()
    }

    func add(_ camera: Camera) { cameras.append(camera) }

    func update(_ camera: Camera) {
        guard let i = cameras.firstIndex(where: { $0.id == camera.id }), cameras[i] != camera else { return }
        cameras[i] = camera
    }

    func remove(_ id: UUID) {
        cameras.removeAll { $0.id == id }
        passwords[id] = nil
        savePasswords()
        OverlayPrefs.remove(id)
    }

    private func saveCameras() {
        if let data = try? JSONEncoder().encode(cameras) {
            UserDefaults.standard.set(data, forKey: camerasKey)
        }
    }

    private func savePasswords() {
        let dict = Dictionary(uniqueKeysWithValues: passwords.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(dict) { Keychain.write(data) }
    }
}

/// Tutte le password in un'unica voce del Portachiavi (un solo prompt di accesso).
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "RTSPOverlay",
        kSecAttrAccount as String: "camera-passwords",
    ]

    static func read() -> Data? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func write(_ data: Data) {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}

/// Preferenze per ogni finestra overlay.
struct OverlayPrefs: Codable {
    var opacity = 1.0
    var alwaysOnTop = true
    var quality: StreamQuality?

    private static func key(_ id: UUID) -> String { "overlay-prefs-\(id.uuidString)" }

    static func load(_ id: UUID) -> OverlayPrefs {
        guard let data = UserDefaults.standard.data(forKey: key(id)),
              let prefs = try? JSONDecoder().decode(OverlayPrefs.self, from: data) else { return OverlayPrefs() }
        return prefs
    }

    func save(_ id: UUID) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key(id)) }
    }

    static func remove(_ id: UUID) { UserDefaults.standard.removeObject(forKey: key(id)) }
}
