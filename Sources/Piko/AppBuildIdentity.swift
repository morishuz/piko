import Foundation

struct AppBuildIdentity: Equatable {
    let version: String
    let build: String
    let sourceRevision: String
    let sourceDirty: Bool?

    init(version: String?, build: String?, sourceRevision: String?, sourceDirty: Bool?) {
        func numericVersion(_ value: String?) -> String {
            guard let value, !value.isEmpty, value.count <= 32,
                value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 })
            else { return "development" }
            return value
        }
        self.version = numericVersion(version)
        self.build = numericVersion(build)
        if let sourceRevision {
            let normalized = sourceRevision.lowercased()
            self.sourceRevision =
                normalized.count == 40
                    && normalized.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                ? normalized : "unknown"
        } else {
            self.sourceRevision = "unknown"
        }
        self.sourceDirty = sourceDirty
    }

    init(bundleInfo: [String: Any]) {
        let dirty: Bool?
        if let value = bundleInfo["PikoSourceDirty"] as? Bool {
            dirty = value
        } else if let value = bundleInfo["PikoSourceDirty"] as? String {
            switch value.lowercased() {
            case "true", "yes", "1": dirty = true
            case "false", "no", "0": dirty = false
            default: dirty = nil
            }
        } else {
            dirty = nil
        }
        self.init(
            version: bundleInfo["CFBundleShortVersionString"] as? String,
            build: bundleInfo["CFBundleVersion"] as? String,
            sourceRevision: bundleInfo["PikoSourceRevision"] as? String,
            sourceDirty: dirty)
    }
}
