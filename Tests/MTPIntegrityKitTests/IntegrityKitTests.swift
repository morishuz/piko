import Foundation
import Testing

@testable import MTPIntegrityKit

@Test func integrityKitRoundTripRejectsCorruptionMissingAndExtraFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mtp-kit-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try IntegrityKit.generate(at: root)
    let source = root.appendingPathComponent("MTP-Synthetic")
    let verified = try IntegrityKit.verify(root: source)
    #expect(verified.files == 14)
    #expect(verified.bytes > 8 * 1024 * 1024)
    #expect(throws: (any Error).self) { try IntegrityKit.generate(at: root) }
    let extra = source.appendingPathComponent("unexpected")
    try Data([1]).write(to: extra)
    #expect(throws: (any Error).self) { try IntegrityKit.verify(root: source) }
    try FileManager.default.removeItem(at: extra)
    let damaged = source.appendingPathComponent("日本語 📷.txt")
    try Data(repeating: 0, count: 97).write(to: damaged)
    #expect(throws: (any Error).self) { try IntegrityKit.verify(root: source) }
    try FileManager.default.removeItem(at: damaged)
    #expect(throws: (any Error).self) { try IntegrityKit.verify(root: source) }
}

@Test func integrityKitRejectsSymlinksAndIgnoresFinderMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mtp-kit-links-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try IntegrityKit.generate(at: root)
    let source = root.appendingPathComponent("MTP-Synthetic")
    try Data([0]).write(to: source.appendingPathComponent(".DS_Store"))
    _ = try IntegrityKit.verify(root: source)
    let victim = source.appendingPathComponent(".hidden-test")
    try FileManager.default.removeItem(at: victim)
    try FileManager.default.createSymbolicLink(
        at: victim, withDestinationURL: source.appendingPathComponent("日本語 📷.txt"))
    #expect(throws: (any Error).self) { try IntegrityKit.verify(root: source) }
}
