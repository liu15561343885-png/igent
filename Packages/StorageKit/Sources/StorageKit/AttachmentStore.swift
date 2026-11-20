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
    /// 删除没有被任何事件引用的文件。
    ///
    /// 图片内容寻址、跨会话共享，删除会话时无法判断"这个文件还有人用吗"，
    /// 所以改成按引用集合反向清理。顺带也收拾掉崩溃留下的半截文件。
    @discardableResult
    public func prune(referenced: Set<String>, minimumAge: TimeInterval = 0) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        // 枚举器会规范化符号链接（iOS 上是 /var → /private/var），
        // 而 root.path 不会。两边都取规范化路径才能正确求相对路径；
        // 前缀对不上就跳过——宁可不删，也不能把被引用的文件删掉。
        let canonicalRoot = root.resolvingSymlinksInPath().path
        var removed = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }

            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(canonicalRoot + "/") else { continue }
            let relative = String(path.dropFirst(canonicalRoot.count + 1))
            guard !referenced.contains(relative) else { continue }

            // 刚存盘的文件可能还没被任何事件引用（选图后未发送、生成中的图片）。
            // 给一个宽限期，避免"清理"把正在编辑的消息里的图片删掉。
            if minimumAge > 0,
               let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                   .contentModificationDate,
               Date().timeIntervalSince(modified) < minimumAge {
                continue
            }

            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

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
