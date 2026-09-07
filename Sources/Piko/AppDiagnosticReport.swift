import Foundation
import MTPWire

struct AppDiagnosticReport: Encodable {
    let schemaVersion = 7
    let appVersion: String
    let build: String
    let macOS: String
    let backend = "swift-apple-usb"
    let scope = "app-actions-and-swift-wire-usb"
    let sourceRevision: String
    let sourceDirty: Bool?
    let includesFileDetails: Bool
    let log: DiagnosticSnapshot
    let previousSession: PersistedDiagnosticSession?
    /// Last recorded session when this launch has never enabled recording.
    let savedSession: PersistedDiagnosticSession?

    init(
        log: DiagnosticLog, version: String?, build: String?,
        sourceRevision: String? = nil, sourceDirty: Bool? = nil,
        previousSession: PersistedDiagnosticSession? = nil,
        savedSession: PersistedDiagnosticSession? = nil,
        includeFileDetails: Bool = false
    ) {
        // Bundle metadata is not a channel for arbitrary strings in exports.
        let identity = AppBuildIdentity(
            version: version, build: build, sourceRevision: sourceRevision, sourceDirty: sourceDirty)
        appVersion = identity.version
        self.build = identity.build
        self.sourceRevision = identity.sourceRevision
        self.sourceDirty = identity.sourceDirty
        macOS = Self.macOSVersion()
        includesFileDetails = includeFileDetails
        let snapshot = log.snapshot()
        self.log = includeFileDetails ? snapshot : snapshot.excludingDetails()
        self.previousSession = previousSession?.filtered(includeFileDetails: includeFileDetails)
        self.savedSession = savedSession?.filtered(includeFileDetails: includeFileDetails)
    }

    static func macOSVersion(_ os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion)
        -> String
    {
        "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
