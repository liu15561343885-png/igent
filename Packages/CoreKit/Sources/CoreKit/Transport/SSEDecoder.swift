import Foundation

/// 一个已解析的 SSE 帧。
public struct SSEEvent: Sendable, Equatable {
    /// `event:` 字段，缺省为 nil。
    public var event: String?
    /// 多个 `data:` 行以 `\n` 连接。
    public var data: String
    /// `id:` 字段（跨帧粘性）。
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// 字节级 SSE 解码器。
///
/// 关键设计：**只对完整行做 UTF-8 解码**。行的终止符是 0x0A，它不可能出现在
/// 任何 UTF-8 多字节序列内部，所以按行切分永远不会把汉字劈成两半。
/// 缓冲未完成的行，而不是对半截字节调用 `String(decoding:)`。
public struct SSEDecoder: Sendable {
    private var lineBuffer: [UInt8] = []
    private var dataLines: [String] = []
    private var eventName: String?
    private var lastEventID: String?
    private let maxBufferedBytes: Int

    /// - Parameter maxBufferedBytes: 防御性上限。上游异常不换行时不至于吃光内存。
    public init(maxBufferedBytes: Int = 8 << 20) {
        self.maxBufferedBytes = maxBufferedBytes
    }

    /// 喂入一段字节，返回其中已完整成帧的事件。
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
        lineBuffer.append(contentsOf: bytes)

        var events: [SSEEvent] = []
        var lineStart = 0
        var cursor = 0
        while cursor < lineBuffer.count {
            if lineBuffer[cursor] == 0x0A {
                let line = stripTrailingCR(lineBuffer[lineStart..<cursor])
                if let event = consume(line: line) { events.append(event) }
                lineStart = cursor + 1
            }
            cursor += 1
        }
        if lineStart > 0 {
            lineBuffer.removeFirst(lineStart)
        }
        if lineBuffer.count > maxBufferedBytes {
            lineBuffer.removeAll(keepingCapacity: true)
        }
        return events
    }

    /// 流结束：把没有以空行收尾的最后一帧冲刷出来。
    ///
    /// 实测不少厂商在最后一个 `data:` 之后直接断流，不补空行。
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !lineBuffer.isEmpty {
            let line = stripTrailingCR(lineBuffer[...])
            if let event = consume(line: line) { events.append(event) }
            lineBuffer.removeAll(keepingCapacity: true)
        }
        if let event = dispatch() { events.append(event) }
        return events
    }

    // MARK: - 行处理

    private func stripTrailingCR(_ slice: ArraySlice<UInt8>) -> [UInt8] {
        var line = Array(slice)
        if line.last == 0x0D { line.removeLast() }
        return line
    }

    private mutating func consume(line: [UInt8]) -> SSEEvent? {
        if line.isEmpty {
            return dispatch()
        }
        // ':' 开头的整行是注释，也是厂商的保活心跳。
        if line[0] == 0x3A { return nil }

        let text = String(decoding: line, as: UTF8.self)
        guard let colon = text.firstIndex(of: ":") else {
            apply(field: text, value: "")
            return nil
        }
        let field = String(text[text.startIndex..<colon])
        var value = String(text[text.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        apply(field: field, value: value)
        return nil
    }

    private mutating func apply(field: String, value: String) {
        switch field {
        case "data": dataLines.append(value)
        case "event": eventName = value
        case "id": lastEventID = value
        default: break
        }
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            dataLines.removeAll(keepingCapacity: true)
            eventName = nil
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(
            event: eventName,
            data: dataLines.joined(separator: "\n"),
            id: lastEventID
        )
    }
}
