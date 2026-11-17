import Foundation

public struct RouterProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var routerURLString: String
    public var wifiSSIDs: [String]
    public var hashPreference: AuthHashPreference

    public init(
        id: UUID = UUID(),
        name: String,
        routerURLString: String,
        wifiSSIDs: [String] = [],
        hashPreference: AuthHashPreference = .auto
    ) {
        self.id = id
        self.name = name
        self.routerURLString = routerURLString
        self.wifiSSIDs = wifiSSIDs
        self.hashPreference = hashPreference
    }

    public static func normalizeSSIDList(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，\n")
        var seen: Set<String> = []
        var result: [String] = []
        for piece in raw.components(separatedBy: separators) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    public func matches(ssid: String) -> Bool {
        let target = ssid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return false }
        return wifiSSIDs.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
        }
    }
}

public enum RouterProfileMatcher {
    public static func match(ssid: String?, in profiles: [RouterProfile]) -> RouterProfile? {
        guard let ssid else { return nil }
        let trimmed = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return profiles.first { $0.matches(ssid: trimmed) }
    }
}
