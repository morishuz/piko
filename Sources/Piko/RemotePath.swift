import Foundation
import MTPWire

enum RemotePath {
    static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func validate(_ directory: String) throws {
        guard directory.hasPrefix("/"), directory == "/" || !directory.hasSuffix("/") else {
            throw BackendError.invalidPath(directory)
        }
        if directory != "/" {
            for part in directory.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
                try RemotePath.validateName(String(part))
            }
        }
    }
    static func validateName(_ name: String) throws {
        guard MTPObjectName.isSafePathComponent(name) else {
            throw BackendError.invalidPath(name)
        }
    }

    /// Join already-validated remote components without local URL normalization.
    static func appending(_ name: String, to directory: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }
}
