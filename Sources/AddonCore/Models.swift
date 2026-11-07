import Foundation

public struct Addon: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var repository: String
    public var assetName: String
    public var addonDirectory: String
    public var automaticUpdates: Bool
    public var installedReleaseID: Int64?
    public var installedAssetID: Int64?
    public var installedDigest: String?
    public var installedTag: String?
    public var managedDirectory: String?
    public var lastStatus: String

    public init(name: String, repository: String, assetName: String, addonDirectory: String, automaticUpdates: Bool = true) {
        self.id = UUID()
        self.name = name
        self.repository = repository
        self.assetName = assetName
        self.addonDirectory = addonDirectory
        self.automaticUpdates = automaticUpdates
        self.lastStatus = "尚未检查"
    }
}

public struct AppSettings: Codable, Sendable {
    public var directoryPath: String = ""
    public var addons: [Addon] = []
    public var history: [HistoryEntry] = []
    public init() {}
}

public struct HistoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let message: String
    public init(message: String) {
        self.id = UUID()
        self.date = Date()
        self.message = message
    }
}

public enum AddonError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}
