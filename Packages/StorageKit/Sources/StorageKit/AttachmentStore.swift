import CoreKit
import CryptoKit
import Foundation

/// 图片附件的落盘存储。内容寻址：同一张图只存一份。
///
/// 路径一律存**相对**路径：iOS 沙盒的绝对路径在重装、备份恢复后会变，
/// 存绝对路径等于埋一个只在特定时刻炸的 bug。
public actor AttachmentStore {
    private let root: URL
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    public func save(_ normalized: NormalizedImage) throws -> ImageAttachmentRef {
        let id = Self.digest(of: normalized.data)
        let relative = Self.relativePath(for: id, mediaType: normalized.mediaType)
        let destination = root.appendingPathComponent(relative)

        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try normalized.data.write(to: destination, options: .atomic)
        }

        return ImageAttachmentRef(
            id: id,
            mediaType: normalized.mediaType,
            byteCount: normalized.data.count,
            width: normalized.width,
            height: normalized.height,
            relativePath: relative
        )
    }

    public func data(for ref: ImageAttachmentRef) throws -> Data {
        guard let relative = ref.relativePath else {
            throw AttachmentError.missingPath(ref.id)
        }
        let url = root.appendingPathComponent(relative)
        guard fileManager.fileExists(atPath: url.path) else {
            throw AttachmentError.fileNotFound(relative)
        }
        return try Data(contentsOf: url)
    }

    public func exists(_ ref: ImageAttachmentRef) -> Bool {
        guard let relative = ref.relativePath else { return false }
        return fileManager.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    @discardableResult
    public func delete(_ ref: ImageAttachmentRef) -> Bool {
        guard let relative = ref.relativePath else { return false }
        let url = root.appendingPathComponent(relative)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        return (try? fileManager.removeItem(at: url)) != nil
    }

    // MARK: - 命名

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 按哈希前两位分桶，避免单目录堆上万个文件。
    static func relativePath(for id: String, mediaType: String) -> String {
        let fileExtension = mediaType == "image/png" ? "png" : "jpg"
        let bucket = String(id.prefix(2))
        return "\(bucket)/\(id).\(fileExtension)"
    }
}

public enum AttachmentError: Error, Equatable {
    case missingPath(String)
    case fileNotFound(String)
}
