/**
 * 统一存储限额与有界文本工具：字节 / 字符预算在 Unicode scalar 边界截断，身份字段超长时置空。
 * @author helele
 * @since 2026-11-09
 */
import Foundation

/// 统一限额；避免后台常驻逐渐变成全量内存缓存。
enum StorageLimits {
    static let pageSize = 60
    static let maximumLoaded = 300
    static let maximumEntries = 10_000
    static let maximumBytes = 1_000_000_000
    static let maximumCaptureBytes = 16 * 1024 * 1024
    static let maximumRepresentationBytes = 8 * 1024 * 1024
    static let maximumRepresentations = 24
    static let titleCharacters = 120
    static let titleBytes = 4 * 1024
    static let excerptCharacters = 240
    static let excerptBytes = 8 * 1024
    static let searchableCharacters = 32_768
    static let searchableBytes = 128 * 1024
    static let sourceBytes = 1024
    static let sourceBundleIDBytes = 1024
    static let queryCharacters = 256
    static let queryBytes = 8 * 1024
    static let groupNameCharacters = 20
    static let groupNameBytes = 1024
}

/// 先限制 UTF-8 输出，再遍历有界字符串的 Character；超长组合字符也不能绕过字节预算。
/// 截断只发生在 scalar 边界；原始非法 UTF-8 可修复，但修复字符同样计入输出预算。
enum BoundedText {
    static func prefix(_ value: String, maximumBytes: Int, maximumCharacters: Int? = nil) -> String {
        guard maximumBytes > 0, maximumCharacters.map({ $0 > 0 }) ?? true else { return "" }
        var result = ""
        var bytes = 0
        for scalar in value.unicodeScalars {
            let width = utf8Width(scalar)
            guard width <= maximumBytes - bytes else { break }
            result.unicodeScalars.append(scalar)
            bytes += width
        }
        return characterPrefix(result, maximumCharacters: maximumCharacters)
    }

    /// 直接遍历 Data / SQLite 列指针，绝不先构造与原输入等大的 String。
    /// decoder 可查看下一 scalar 的最多 4 个字节，避免将有效 UTF-8 的截断尾部误修复为 U+FFFD。
    static func decode<Bytes: Collection>(_ data: Bytes, maximumBytes: Int,
                                         maximumCharacters: Int? = nil) -> String where Bytes.Element == UInt8 {
        guard maximumBytes > 0, maximumCharacters.map({ $0 > 0 }) ?? true else { return "" }
        var iterator = data.makeIterator()
        var decoder = Unicode.UTF8()
        var result = ""
        var bytes = 0
        while bytes < maximumBytes {
            let scalar: Unicode.Scalar
            switch decoder.decode(&iterator) {
            case .scalarValue(let value): scalar = value
            case .error: scalar = "\u{FFFD}"
            case .emptyInput: return characterPrefix(result, maximumCharacters: maximumCharacters)
            }
            let width = utf8Width(scalar)
            guard width <= maximumBytes - bytes else { break }
            result.unicodeScalars.append(scalar)
            bytes += width
        }
        return characterPrefix(result, maximumCharacters: maximumCharacters)
    }

    static func fits(_ value: String, maximumBytes: Int, maximumCharacters: Int? = nil) -> Bool {
        guard maximumBytes >= 0, value.utf8.prefix(maximumBytes + 1).count <= maximumBytes else { return false }
        guard let maximumCharacters else { return true }
        return maximumCharacters >= 0 && value.prefix(maximumCharacters + 1).count <= maximumCharacters
    }

    private static func utf8Width(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case ...0x7F: 1
        case ...0x7FF: 2
        case ...0xFFFF: 3
        default: 4
        }
    }

    private static func characterPrefix(_ value: String, maximumCharacters: Int?) -> String {
        guard let maximumCharacters else { return value }
        return String(value.prefix(max(0, maximumCharacters)))
    }

    /// 每条采集共享一个输出预算，换行分隔符同样计费；不拼接无界数组后再截断。
    struct Builder {
        private(set) var value = ""
        private var remainingBytes: Int
        private var remainingCharacters: Int?

        init(maximumBytes: Int = StorageLimits.searchableBytes,
             maximumCharacters: Int? = StorageLimits.searchableCharacters) {
            remainingBytes = max(0, maximumBytes)
            remainingCharacters = maximumCharacters.map { max(0, $0) }
        }

        var isFull: Bool { remainingBytes == 0 || remainingCharacters == 0 }

        mutating func append(_ text: String) {
            appendBounded { bytes, characters in
                BoundedText.prefix(text, maximumBytes: bytes, maximumCharacters: characters)
            }
        }

        mutating func appendUTF8<Bytes: Collection>(_ data: Bytes) where Bytes.Element == UInt8 {
            appendBounded { bytes, characters in
                BoundedText.decode(data, maximumBytes: bytes, maximumCharacters: characters)
            }
        }

        private mutating func appendBounded(_ make: (Int, Int?) -> String) {
            let separator = value.isEmpty ? "" : "\n"
            let cost = value.isEmpty ? 0 : 1
            guard remainingBytes > cost, remainingCharacters.map({ $0 > cost }) ?? true else { return }
            let bounded = make(remainingBytes - cost, remainingCharacters.map { $0 - cost })
            guard !bounded.isEmpty else { return }
            value += separator
            value += bounded
            remainingBytes -= cost + bounded.utf8.count
            if let characters = remainingCharacters { remainingCharacters = characters - cost - bounded.count }
        }
    }
}

/// 采集、持久化和 UI 共用字段预算；身份字段超长时置空，不能截成另一个应用身份。
enum MetadataBounds {
    static func title(_ value: String) -> String {
        BoundedText.prefix(value, maximumBytes: StorageLimits.titleBytes, maximumCharacters: StorageLimits.titleCharacters)
    }
    static func excerpt(_ value: String) -> String {
        BoundedText.prefix(value, maximumBytes: StorageLimits.excerptBytes, maximumCharacters: StorageLimits.excerptCharacters)
    }
    static func search(_ value: String) -> String {
        BoundedText.prefix(value, maximumBytes: StorageLimits.searchableBytes, maximumCharacters: StorageLimits.searchableCharacters)
    }
    static func source(_ value: String) -> String {
        BoundedText.prefix(value, maximumBytes: StorageLimits.sourceBytes)
    }
    static func sourceBundleID(_ value: String) -> String {
        BoundedText.fits(value, maximumBytes: StorageLimits.sourceBundleIDBytes) ? value : ""
    }
    static func query(_ value: String) -> String {
        BoundedText.prefix(value, maximumBytes: StorageLimits.queryBytes, maximumCharacters: StorageLimits.queryCharacters)
    }
    static func normalizedGroupName(_ value: String) -> String? {
        guard BoundedText.fits(value, maximumBytes: StorageLimits.groupNameBytes) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, BoundedText.fits(trimmed, maximumBytes: StorageLimits.groupNameBytes,
                                               maximumCharacters: StorageLimits.groupNameCharacters) else { return nil }
        return trimmed
    }

    static func normalize(_ capture: ClipCapture) -> ClipCapture {
        ClipCapture(kind: capture.kind, title: title(capture.title), excerpt: excerpt(capture.excerpt),
            searchText: search(capture.searchText), source: source(capture.source),
            sourceBundleID: sourceBundleID(capture.sourceBundleID), representations: capture.representations)
    }
}
