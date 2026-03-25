import XCTest
@testable import xmnote

@MainActor
final class XMAttachmentUploadRenderSourceResolverTests: XCTestCase {
    func testResolvePrefersLocalWhenFileExists() {
        let result = XMAttachmentUploadRenderSourceResolver.resolve(
            localFilePath: "/tmp/local.jpg",
            remoteURL: "https://example.com/remote.jpg",
            fileExists: { path in
                path == "/tmp/local.jpg"
            }
        )

        XCTAssertEqual(result, .local(path: "/tmp/local.jpg"))
    }

    func testResolveFallsBackToRemoteWhenLocalFileMissing() {
        let result = XMAttachmentUploadRenderSourceResolver.resolve(
            localFilePath: "/tmp/local.jpg",
            remoteURL: "https://example.com/remote.jpg",
            fileExists: { _ in false }
        )

        XCTAssertEqual(result, .remote(url: URL(string: "https://example.com/remote.jpg")!))
    }

    func testResolveReturnsNoneWhenBothSourcesInvalid() {
        let result = XMAttachmentUploadRenderSourceResolver.resolve(
            localFilePath: "",
            remoteURL: "ftp://example.com/image.jpg",
            fileExists: { _ in false }
        )

        XCTAssertEqual(result, .none)
    }

    func testResolveTrimsLocalPathBeforeExistenceCheck() {
        let result = XMAttachmentUploadRenderSourceResolver.resolve(
            localFilePath: "  /tmp/local.jpg  ",
            remoteURL: nil,
            fileExists: { path in
                path == "/tmp/local.jpg"
            }
        )

        XCTAssertEqual(result, .local(path: "/tmp/local.jpg"))
    }
}
