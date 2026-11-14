import CryptoKit
import Foundation

/// Short-lived identity evidence returned by the authorized ADB shell.
/// It is intentionally not Codable and must never be written to repositories or preferences.
struct DeviceIdentityEvidence: Hashable, Sendable {
    let serialNumber: String
    let manufacturer: String
    let model: String

    init(serialNumber: String, manufacturer: String, model: String) throws {
        let values = [serialNumber, manufacturer, model].map(Self.removingOutputTerminators)
        guard values.allSatisfy(Self.isUsable), values.allSatisfy({ $0.utf8.count <= 256 }) else {
            throw EngineError.invalidIdentifier
        }
        self.serialNumber = values[0]
        self.manufacturer = values[1]
        self.model = values[2]
    }

    static func parse(_ output: Data) throws -> Self {
        var fields = output.split(separator: 0, omittingEmptySubsequences: false)
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count == 3,
              let serial = String(data: Data(fields[0]), encoding: .utf8),
              let manufacturer = String(data: Data(fields[1]), encoding: .utf8),
              let model = String(data: Data(fields[2]), encoding: .utf8) else {
            throw EngineError.invalidIdentifier
        }
        return try Self(serialNumber: serial, manufacturer: manufacturer, model: model)
    }

    var deviceID: DeviceID {
        var framed = Data("org.androdo.device-identity.v1".utf8)
        for value in [serialNumber, manufacturer, model] {
            let bytes = Data(value.utf8)
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
            framed.append(bytes)
        }
        let digest = SHA256.hash(data: framed).map { String(format: "%02x", $0) }.joined()
        return try! DeviceID(value: "android-device:v1:\(digest)")
    }

    private static func removingOutputTerminators(_ value: String) -> String {
        var result = value
        while result.last == "\n" || result.last == "\r" { result.removeLast() }
        return result
    }

    private static func isUsable(_ value: String) -> Bool {
        guard !value.isEmpty, !value.utf8.contains(0) else { return false }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if ["unknown", "null", "none", "n/a", "not set", "unspecified", "0"].contains(normalized) {
            return false
        }
        if normalized.allSatisfy({ $0 == "0" || $0 == "-" }) { return false }
        return true
    }
}
