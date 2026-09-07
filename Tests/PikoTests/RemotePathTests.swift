import Foundation
import Testing
@testable import Piko

@Test func remotePathJoiningPreservesDeviceSpelling() throws {
    // Do not apply file-URL percent decoding, case folding or Unicode normalization
    // when reconstructing a device path. Conflict comparison is separate.
    for name in ["a%2Fb.txt", "日本語 📷.txt", "e\u{301}.txt", "É.txt"] {
        try RemotePath.validateName(name)
        let path = RemotePath.appending(name, to: "/Photos")
        try RemotePath.validate(path)
        #expect(Array(path.utf8) == Array(("/Photos/" + name).utf8))
        #expect(RemotePath.appending(name, to: "/") == "/" + name)
    }
    #expect(RemotePath.collisionKey("É.txt") == RemotePath.collisionKey("e\u{301}.TXT"))
    for invalid in ["relative", "//Photos", "/Photos/", "/Photos/../file", "/Photos/./file"] {
        #expect(throws: BackendError.self) { try RemotePath.validate(invalid) }
    }
}
