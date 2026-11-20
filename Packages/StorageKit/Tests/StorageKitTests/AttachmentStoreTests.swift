import CoreKit
import Foundation
import XCTest
@testable import StorageKit

final class AttachmentStoreTests: XCTestCase {
    private var root: URL!
    private var store: AttachmentStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("igent-attachments-\(UUID().uuidString)")
        store = try AttachmentStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func image(_ bytes: [UInt8] = [0x01, 0x02, 0x03], width: Int = 64, height: Int = 48) -> NormalizedImage {
        NormalizedImage(data: Data(bytes), mediaType: "image/jpeg", width: width, height: height)
    }

    func testSaveAndLoadRoundTrip() async throws {
        let source = image()
        let ref = try await store.save(source)

        XCTAssertEqual(ref.width, 64)
        XCTAssertEqual(ref.height, 48)
        XCTAssertEqual(ref.mediaType, "image/jpeg")
        XCTAssertEqual(ref.byteCount, 3)

        let loaded = try await store.data(for: ref)
        XCTAssertEqual(loaded, source.data)
    }

    /// 内容寻址：同样的字节只落一个文件，id 相同。
    func testDeduplicatesByIdenticalBytes() async throws {
        let first = try await store.save(image())
        let second = try await store.save(image())
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.relativePath, second.relativePath)

        let directory = root.appendingPathComponent(String(first.id.prefix(2)))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.count, 1)
    }

    func testDifferentBytesGetDifferentIDs() async throws {
        let first = try await store.save(image([0x01]))
        let second = try await store.save(image([0x02]))
        XCTAssertNotEqual(first.id, second.id)
    }

    /// 存的是相对路径——绝对路径在重装后会失效。
    func testStoresRelativePath() async throws {
        let ref = try await store.save(image())
        let path = try XCTUnwrap(ref.relativePath)
        XCTAssertFalse(path.hasPrefix("/"), "不能存绝对路径：\(path)")
        XCTAssertTrue(path.hasSuffix(".jpg"))
    }

    func testDeleteRemovesFile() async throws {
        let ref = try await store.save(image())
        let existsBefore = await store.exists(ref)
        XCTAssertTrue(existsBefore)
        await store.delete(ref)
        let existsAfter = await store.exists(ref)
        XCTAssertFalse(existsAfter)
        XCTAssertThrowsError(try Data(contentsOf: root.appendingPathComponent(ref.relativePath!)))
    }

    func testMissingFileThrows() async throws {
        let ref = ImageAttachmentRef(
            id: "ffff",
            mediaType: "image/jpeg",
            byteCount: 1,
            width: 1,
            height: 1,
            relativePath: "ff/none.jpg"
        )
        do {
            _ = try await store.data(for: ref)
            XCTFail("应当抛错")
        } catch let error as AttachmentError {
            XCTAssertEqual(error, .fileNotFound("ff/none.jpg"))
        }
    }

    func testRefWithoutPathThrows() async throws {
        let ref = ImageAttachmentRef(id: "x", mediaType: "image/jpeg", byteCount: 1, width: 1, height: 1)
        do {
            _ = try await store.data(for: ref)
            XCTFail("应当抛错")
        } catch let error as AttachmentError {
            XCTAssertEqual(error, .missingPath("x"))
        }
    }

    /// 哈希分桶：路径第一段是 id 前两位。
    func testBucketedLayout() async throws {
        let ref = try await store.save(image())
        let path = try XCTUnwrap(ref.relativePath)
        XCTAssertEqual(String(path.prefix(2)), String(ref.id.prefix(2)))
    }
}

final class StorageImageResolverTests: XCTestCase {
    func testResolvesStoredImageToBase64() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("igent-resolver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AttachmentStore(root: root)
        let ref = try await store.save(
            NormalizedImage(data: Data([0x41, 0x42, 0x43]), mediaType: "image/jpeg", width: 1, height: 1)
        )

        let resolver = StorageImageResolver(store: store)
        let payloads = await resolver.resolve([ref])

        XCTAssertEqual(payloads[ref.id]?.base64, "QUJD")
        XCTAssertEqual(payloads[ref.id]?.mediaType, "image/jpeg")
    }

    /// 文件丢了就跳过，不能整条请求因此失败。
    func testMissingFileIsSkipped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("igent-resolver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try AttachmentStore(root: root)
        let missing = ImageAttachmentRef(
            id: "gone",
            mediaType: "image/jpeg",
            byteCount: 1,
            width: 1,
            height: 1,
            relativePath: "go/gone.jpg"
        )
        let resolver = StorageImageResolver(store: store)
        let payloads = await resolver.resolve([missing])
        XCTAssertTrue(payloads.isEmpty)
    }
}
