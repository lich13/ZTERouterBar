import CryptoKit
import Foundation

public enum AuthHashPreference: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto
    case sha256
    case md5

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: "自动识别 (推荐)"
        case .sha256: "SHA-256 (MU5120 / MC888 / MC889)"
        case .md5: "MD5 (旧款 ZTE 固件)"
        }
    }
}

public enum ResolvedHashAlgorithm: String, Sendable, Equatable {
    case sha256
    case md5

    public static func resolve(
        waInnerVersion: String,
        preference: AuthHashPreference
    ) -> ResolvedHashAlgorithm {
        switch preference {
        case .sha256:
            return .sha256
        case .md5:
            return .md5
        case .auto:
            let upper = waInnerVersion.uppercased()
            let legacyMD5Markers = ["MC801", "MC802", "MF286", "MF289", "MF297", "MF9"]
            if legacyMD5Markers.contains(where: { upper.contains($0) }) {
                return .md5
            }
            // MU5120 (BD_FLYMODEMMU5120...), MC888, MC889, MU500x, U50, and newer WebUIs use SHA-256.
            return .sha256
        }
    }
}

public enum RouterCrypto {
    /// Uppercase 64-char SHA-256 hex digest matching ZTE's `js/util.js` (`d = 1`).
    public static func sha256Upper(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    /// Lowercase 32-char MD5 hex digest matching ZTE's `hex_md5` on legacy firmware.
    public static func md5Lower(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes `SHA256(SHA256(plainPassword) + LD)` in uppercase hex.
    public static func computeLoginPassword(plainPassword: String, ld: String) -> String {
        let baseHash = sha256Upper(plainPassword)
        return sha256Upper(baseHash + ld)
    }

    /// Computes `AD = hash(hash(wa_inner_version + cr_version) + RD)`.
    public static func computeAD(
        waInnerVersion: String,
        crVersion: String,
        rd: String,
        algorithm: ResolvedHashAlgorithm
    ) -> String {
        switch algorithm {
        case .sha256:
            let versionHash = sha256Upper(waInnerVersion + crVersion)
            return sha256Upper(versionHash + rd)
        case .md5:
            let versionHash = md5Lower(waInnerVersion + crVersion)
            return md5Lower(versionHash + rd)
        }
    }
}
