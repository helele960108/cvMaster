/**
 * 轻量历史元数据与内容传输模型；列表不持有原图、文件本体或完整正文。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 明确使用属性包装器，避免命令行 SDK 将同名 State 解析为外部宏。
typealias ViewState<Value> = SwiftUI.State<Value>

/// 外观偏好使用稳定字符串持久化；system 不固定颜色，由 macOS 自动切换。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    /// 用于原生 Picker 的稳定标识，不依赖本地化显示名称。
    var id: String { rawValue }

    /// 设置中显示的外观选项。
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    /// nil 撤销应用级覆盖，让浮层、材质、菜单和设置随系统外观变化。
    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// 支持的主要展示类型，同一条目仍可保留多种原始表示。
enum ClipKind: String, CaseIterable, Identifiable, Sendable {
    case text = "文本", link = "链接", image = "图片", file = "文件"
    var id: String { rawValue }

    /// 持久化键与显示文案分离；修改中文名称不需要迁移历史内容。
    var storageValue: String {
        switch self {
        case .text: "text"
        case .link: "link"
        case .image: "image"
        case .file: "file"
        }
    }

    static func fromStorageValue(_ value: String) -> ClipKind {
        switch value {
        case "text", "文本": .text
        case "link", "链接": .link
        case "image", "图片": .image
        case "file", "文件": .file
        // 未知分类仍允许查看和恢复原始表示，不因一条异常记录阻断整页。
        default: .text
        }
    }

    /// SF Symbols 系统符号，搭配类型名称提供可访问语义。
    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }
}

/// 分页列表中的轻量投影，不包含任何大体积内容。
struct Clip: Identifiable, Sendable {
    /// 数据库中稳定 UUID，重复复制不会改变此标识。
    let id: UUID
    /// 用户可见内容类型；图片文件归图片，混合文件仍归文件。
    let kind: ClipKind
    /// 最多 120 字符的安全纯文本标题。
    let title: String
    /// 尽力推断的来源应用名称，不作绝对准确性承诺。
    let source: String
    /// 采集时推断的来源 Bundle ID；旧记录为空，不按同名应用猜测身份。
    let sourceBundleID: String
    /// 最近复制的本地时间。
    let copiedAt: Date
    /// 已保存表示的总字节数，不代表引用文件本体大小。
    let byteSize: Int
    /// 全局置顶状态。
    let pinned: Bool
    /// 持久化的多对多分组关系。
    let groups: Set<UUID>
    /// 首次采集及主动重复复制的累计次数。
    let copies: Int
    /// 详情的短摘要，不使用完整正文作为列表数据源。
    let excerpt: String

    /// 完整复制时间用于悬停提示和预览，避免跨天记录只有时分造成歧义。
    var time: String { copiedAt.formatted(date: .numeric, time: .standard) }
    /// 原始表示包含文件引用，与用户可见类型独立，避免图片分类改变复制行为。
    let hasFileReference: Bool

    var isImageFile: Bool { kind == .image && hasFileReference }
    var showsImage: Bool { kind == .image }

    var size: String { ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file) }
}

/// 单层持久化分组；颜色为可重建的语义标记，不存储 JSON。
struct ClipGroup: Identifiable, Sendable {
    /// 稳定分组标识，重命名不改变关联。
    let id: UUID
    /// 非空、大小写不重复的分组名称。
    let name: String
    /// 小范围颜色标记，对应固定原生颜色，不序列化 Color。
    let colorIndex: Int
    var color: Color { [Color.brown, .green, .purple, .gray][abs(colorIndex % 4)] }
}

/// 可由 ImageIO 本地解码的栅格剪贴板类型，采集与预览共用，避免白名单不一致。
enum ClipboardFormats {
    /// 按常见无损、压缩格式排列；不包含可能引用外部资源的 SVG 或 HTML。
    static let rasterImages = ["public.png", "public.jpeg", "public.tiff", "public.heic", "public.heif",
                               "com.compuserve.gif", "com.microsoft.bmp", "org.webmproject.webp"]
    /// 仅全部文件名均为图片时归入图片，图片与其他文件混选仍归文件。
    static func areImageFiles(_ names: [String]) -> Bool {
        !names.isEmpty && names.allSatisfy {
            UTType(filenameExtension: ($0 as NSString).pathExtension.lowercased())?.conforms(to: .image) == true
        }
    }

    /// RTF 文本提取预算，防止在后台串行存储中解析超大富文本阻塞其他操作。
    static let maximumRichTextPreviewBytes = 256 * 1024

    /// RTF 使用本地解析，不执行 HTML；解析输入与纯文本输出分别设限。
    static func richText(_ data: Data, maximumBytes: Int = StorageLimits.searchableBytes,
                         maximumCharacters: Int? = StorageLimits.searchableCharacters) -> String? {
        guard !data.isEmpty, data.count <= maximumRichTextPreviewBytes,
              let value = try? NSAttributedString(data: data,
                  options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string else { return nil }
        return BoundedText.prefix(value, maximumBytes: maximumBytes, maximumCharacters: maximumCharacters)
    }
}

/// 单个 pasteboard item 的一种受支持表示，数据只在采集 / 复制期间短暂持有。
struct ClipRepresentation: Sendable {
    /// 原始 item 顺序，用于恢复多个文件 / item。
    let item: Int
    /// 系统剪贴板类型字符串，仅允许受控白名单。
    let type: String
    /// 受单条预算约束的内容，不在列表状态中保留。
    let data: Data
}

/// 从主线程采集后提交后台存储的有界快照。
struct ClipCapture: Sendable {
    let kind: ClipKind
    let title: String
    let excerpt: String
    /// 有限的可搜索纯文本；RTF-only 仅在后台按解析预算补充，不执行 HTML。
    let searchText: String
    let source: String
    /// 采集时推断的来源 Bundle ID；旧记录为空，不按同名应用猜测身份。
    let sourceBundleID: String
    let representations: [ClipRepresentation]
}

/// 全库容量统计，不受搜索、分组或时间筛选影响。
struct StorageStats: Sendable {
    /// 全库记录条数，包含置顶和已分组内容。
    let entries: Int
    /// 全库内容表示总字节，不包含数据库、WAL 和引用文件本体。
    let bytes: Int
}

/// 一次后台分页查询结果；数量独立于当前加载页。
struct HistoryPage: Sendable {
    let clips: [Clip]
    let total: Int
    /// 全库记录条数，不随当前筛选变化。
    let storedEntries: Int
    /// 全库表示字节数，不包含 SQLite 日志及引用文件大小。
    let storedBytes: Int
}

/// 纯文本详情按需加载；对超长内容截断，原始复制仍恢复完整表示。
struct ClipPreview: Sendable {
    let text: String
    /// ImageIO 降采样后的小图，nil 表示不含图片或图片不可解码。
    let thumbnail: Data?
}

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

/// 面向用户的可控失败提示；日志不输出正文、路径或原始 SQL 参数。
enum LibraryError: LocalizedError {
    case storage, capacity, unsupported, missingContent, unavailableFile, nameConflict, missingGroup, plainTextUnavailable, richTextTooLarge
    /// 自动粘贴授权缺失，或当前激活的 APP 不可用；与内容 / 存储错误分别提示。
    case pastePermissionRequired, pasteTargetUnavailable
    var errorDescription: String? {
        switch self {
        case .pastePermissionRequired: "尚未获得辅助功能权限。请在“系统设置 → 隐私与安全性 → 辅助功能”中开启 cvMaster；若已开启仍无效，请移除旧条目后重新添加 ~/Applications/cvMaster.app。剪贴板未改变。"
        case .pasteTargetUnavailable: "未能向当前激活的 APP 发送粘贴，请聚焦可编辑输入框后重新打开列表；若剪贴板已更新，可手动按 ⌘V。"
        case .storage: "本地存储不可用，请检查磁盘空间或重新打开应用。"
        case .capacity: "存储已达上限，请清理记录；置顶和已分组内容不会被自动删除。"
        case .unsupported: "内容格式暂不支持，或超过单条保存限额。"
        case .missingContent: "内容文件不可用，无法再次复制。"
        case .unavailableFile: "原文件已移动、删除或无权访问，无法复制文件引用。"
        case .richTextTooLarge: "RTF 超过 256 KB 纯文本转换预算，未改变剪贴板；仍可使用普通粘贴保留原格式。"
        case .plainTextUnavailable: "此记录没有可用的纯文本或 RTF 表示，无法移除格式；原始剪贴板未改变。"
        case .nameConflict: "分组名称为空、过长或已存在。"
        case .missingGroup: "分组已不存在，请重新选择。"
        }
    }
}

/// 时间范围按用户当前日历和时区计算；近 N 天包含今天及此前 N−1 个自然日。
enum ClipTimeRange: String, CaseIterable, Identifiable, Sendable {
    case all = "全部时间"
    case today = "今天"
    case yesterday = "昨天"
    case last7Days = "近7天"
    case last30Days = "近30天"

    var id: String { rawValue }

    /// 查询开始时固定区间，闭开边界避免午夜重复；不按固定秒数推算自然日。
    func interval(at now: Date, calendar: Calendar = .current) -> DateInterval? {
        guard self != .all, let today = calendar.dateInterval(of: .day, for: now) else { return nil }
        let offset: Int
        switch self {
        case .all: return nil
        case .today: return today
        case .yesterday: offset = -1
        case .last7Days: offset = -6
        case .last30Days: offset = -29
        }
        guard let start = calendar.date(byAdding: .day, value: offset, to: today.start) else { return nil }
        return DateInterval(start: start, end: self == .yesterday ? today.start : today.end)
    }
}

/// 只刷新时间标签，不刷新卡片正文、缩略图或共享列表状态。
struct ClipRelativeTime: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(label(at: context.date)).help(date.formatted(date: .numeric, time: .standard))
        }
    }

    /// 分钟、小时按实际间隔，跨日使用日历天数；异常未来时间不显示负数。
    private func label(at now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60))分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600))小时前" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date),
                                                   to: Calendar.current.startOfDay(for: now)).day ?? 0
        if days == 1 { return "昨天" }
        if days < 7 { return "\(max(1, days))天前" }
        return date.formatted(.dateTime.year().month().day())
    }
}
