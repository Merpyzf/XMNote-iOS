import XCTest
import UIKit
@testable import xmnote

final class XMAttachmentUploadInteractionPolicyTests: XCTestCase {
    func testShouldBeginReorderReturnsFalseWhenTouchedViewIsControl() {
        let button = UIButton(type: .system)

        let result = XMAttachmentUploadInteractionPolicy.shouldBeginReorder(from: button)

        XCTAssertFalse(result)
    }

    func testShouldBeginReorderReturnsFalseWhenTouchedViewIsControlDescendant() {
        let button = UIButton(type: .system)
        let container = UIView()
        let iconView = UIImageView()
        container.addSubview(iconView)
        button.addSubview(container)

        let result = XMAttachmentUploadInteractionPolicy.shouldBeginReorder(from: iconView)

        XCTAssertFalse(result)
    }

    func testShouldBeginReorderReturnsTrueWhenTouchedViewIsNonControl() {
        let plainView = UIView()

        let result = XMAttachmentUploadInteractionPolicy.shouldBeginReorder(from: plainView)

        XCTAssertTrue(result)
    }

    func testShouldBeginReorderReturnsTrueWhenTouchedViewIsNil() {
        let result = XMAttachmentUploadInteractionPolicy.shouldBeginReorder(from: nil)

        XCTAssertTrue(result)
    }

    func testShouldBeginReorderReturnsFalseWhenLocationInsideProtectedFrame() {
        let protectedFrames = [CGRect(x: 12, y: 12, width: 30, height: 30)]

        let result = XMAttachmentUploadInteractionPolicy.shouldBeginReorder(
            at: CGPoint(x: 20, y: 20),
            protectedFrames: protectedFrames
        )

        XCTAssertFalse(result)
    }

    func testShouldBeginReorderReturnsTrueWhenLocationOutsideProtectedFrames() {
        let protectedFrames = [CGRect(x: 12, y: 12, width: 30, height: 30)]

        let result = XMAttachmentUploadInteractionPolicy.shouldBeginReorder(
            at: CGPoint(x: 80, y: 20),
            protectedFrames: protectedFrames
        )

        XCTAssertTrue(result)
    }
}
