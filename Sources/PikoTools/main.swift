import Foundation
import MTPUSB
import MTPIntegrityKit

@main
struct PikoTools {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            if args == ["--list"] {
                let candidates = try await USBTransport.discoverApple()
                for candidate in candidates {
                    print(String(format: "registryID=%llu VID=%04x PID=%04x", candidate.registryID, candidate.vendor, candidate.product))
                }
                print("\(candidates.count) MTP candidate interfaces. Registry only; none opened.")
            } else if args.count == 2 && args[0] == "generate" {
                try IntegrityKit.generate(at: URL(fileURLWithPath: args[1]))
                print("Generated MTP-Synthetic: \(IntegrityKit.fileCount) files.")
            } else if args.count == 2 && args[0] == "verify" {
                let result = try IntegrityKit.verify(root: URL(fileURLWithPath: args[1]))
                print("PASS kit v\(IntegrityKit.version): \(result.files) files, \(result.bytes) bytes; SHA-256 and tree checks matched.")
            } else if args.isEmpty || args == ["--help"] {
                print("""
                    PikoTools \(IntegrityKit.toolVersion)
                    --list                 List cached registry MTP interfaces; opens nothing.
                    generate NEW_FOLDER    Generate synthetic integrity kit; no USB access.
                    verify MTP-Synthetic   Verify downloaded synthetic folder; no USB access.
                    This utility never opens MTP sessions or transfers data over USB.
                    """)
            } else {
                throw USBError.invalidTransfer
            }
        } catch {
            FileHandle.standardError.write(Data("PikoTools failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
