import XCTest
@testable import xmnote

@MainActor
final class XMAttachmentUploadPreviewMapperTests: XCTestCase {
    func testMakeResultBuildsPreviewItemsWithExpectedSourcePriority() {
        let items: [XMAttachmentUploadItem] = [
            .init(id: "local-only", localFilePath: "/tmp/local.jpg", remoteURL: nil, uploadState: .uploading),
            .init(id: "remote-only", localFilePath: nil, remoteURL: "https://example.com/remote.jpg", uploadState: .success),
            .init(id: "both", localFilePath: "/tmp/both-local.jpg", remoteURL: "https://example.com/both-remote.jpg", uploadState: .failed),
            .init(id: "invalid", localFilePath: "invalid path", remoteURL: "ftp://example.com/image.jpg", uploadState: .success)
        ]

        let result = XMAttachmentUploadPreviewMapper.makeResult(from: items)

        XCTAssertEqual(result.previewItems.count, 3)
        XCTAssertEqual(result.previewItems[0], .init(id: "local-only", thumbnailURL: "/tmp/local.jpg", originalURL: "/tmp/local.jpg"))
        XCTAssertEqual(result.previewItems[1], .init(id: "remote-only", thumbnailURL: "https://example.com/remote.jpg", originalURL: "https://example.com/remote.jpg"))
        XCTAssertEqual(result.previewItems[2], .init(id: "both", thumbnailURL: "/tmp/both-local.jpg", originalURL: "https://example.com/both-remote.jpg"))

        XCTAssertEqual(result.previewIndexByItemID["local-only"], 0)
        XCTAssertEqual(result.previewIndexByItemID["remote-only"], 1)
        XCTAssertEqual(result.previewIndexByItemID["both"], 2)
        XCTAssertNil(result.previewIndexByItemID["invalid"])
    }

    func testMakeResultKeepsFirstIndexWhenDuplicateIDsAppear() {
        let items: [XMAttachmentUploadItem] = [
            .init(id: "dup", localFilePath: "/tmp/dup-first.jpg", remoteURL: nil, uploadState: .success),
            .init(id: "dup", localFilePath: nil, remoteURL: "https://example.com/dup-second.jpg", uploadState: .success),
            .init(id: "unique", localFilePath: nil, remoteURL: "https://example.com/unique.jpg", uploadState: .success)
        ]

        let result = XMAttachmentUploadPreviewMapper.makeResult(from: items)

        XCTAssertEqual(result.previewItems.count, 3)
        XCTAssertEqual(result.previewIndexByItemID["dup"], 0)
        XCTAssertEqual(result.previewIndexByItemID["unique"], 2)
        XCTAssertEqual(result.duplicateIDs, ["dup"])
    }

    func testNormalizedSourceAcceptsLocalAndHTTPURLsOnly() {
        XCTAssertEqual(XMAttachmentUploadPreviewMapper.normalizedSource("/tmp/file.jpg"), "/tmp/file.jpg")
        XCTAssertEqual(XMAttachmentUploadPreviewMapper.normalizedSource("https://example.com/a.jpg"), "https://example.com/a.jpg")
        XCTAssertNil(XMAttachmentUploadPreviewMapper.normalizedSource("ftp://example.com/a.jpg"))
        XCTAssertNil(XMAttachmentUploadPreviewMapper.normalizedSource(""))
    }
}
