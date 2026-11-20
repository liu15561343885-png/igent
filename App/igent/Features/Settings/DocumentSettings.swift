import Foundation
import WebSeamKit

/// 文档解析方式。
enum DocumentParsingPurpose: String, CaseIterable, Identifiable {
    /// 只取文字，图表丢弃。更快，适合合同、论文、扫描文本。
    case textRecognition
    /// 文字 + 图表一起识别。更慢，适合财报、幻灯片、带示意图的手册。
    case richLayoutRecognition

    var id: String { rawValue }

    var title: String {
        switch self {
        case .textRecognition: "只识别文字"
        case .richLayoutRecognition: "文字 + 图表"
        }
    }

    var detail: String {
        switch self {
        case .textRecognition: "图表、照片会被丢弃，只保留可读文字"
        case .richLayoutRecognition: "逐页识别，图表位置上的文字也会取到；更慢，价格相同"
        }
    }

    var recognizerPurpose: DeepSeekOCRRecognizer.Purpose {
        switch self {
        case .textRecognition: .textRecognition
        case .richLayoutRecognition: .richLayoutRecognition
        }
    }
}

extension AppEnvironment {
}
