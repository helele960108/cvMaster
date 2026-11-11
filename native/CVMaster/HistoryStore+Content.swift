/**
 * 按需读取已保存表示、纯文本转换与详情预览；共享有界文本与 RTF 预算。
 * @author helele
 * @since 2026-11-09
 */
import Foundation
import AppKit
import SQLite3

extension HistoryStore {
    /// SQLite 语句和保存资产先完整读取并关闭，再挂起检查外部文件；删除代数拒绝过期复制。
    func representations(_ id: UUID) async throws -> [ClipRepresentation] {
        try Task.checkCancellation()
        try prepare()
        let generation = thumbnailCache.generation
        let originals = try savedRepresentations(id)
        var references: [URL] = []
        for representation in originals where representation.type == "public.file-url" {
            guard let value = String(data: representation.data, encoding: .utf8), let url = URL(string: value), url.isFileURL else {
                throw LibraryError.unavailableFile
            }
            references.append(url)
        }
        let available = await FileAvailability.shared.check(references)
        try Task.checkCancellation()
        guard generation == thumbnailCache.generation else { throw LibraryError.missingContent }
        guard available else { throw LibraryError.unavailableFile }
        return originals
    }

    /// fd 相对读取，不跟随符号链接；函数返回前 finalize，不跨 await 保留 SQLite 指针。
    func savedRepresentations(_ id: UUID) throws -> [ClipRepresentation] {
        let query = try statement("SELECT item_order,uti,filename,byte_size FROM representation WHERE entry_id=? ORDER BY item_order,id", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        var result: [ClipRepresentation] = []
        var size = 0
        while try next(query) {
            let expected = Int(sqlite3_column_int64(query, 3))
            guard expected >= 0, expected <= StorageLimits.maximumRepresentationBytes,
                  size <= StorageLimits.maximumCaptureBytes - expected,
                  result.count < StorageLimits.maximumRepresentations else { throw LibraryError.missingContent }
            size += expected
            let data = try assetData(text(query, 2), maximum: expected, expectedSize: expected)
            let type = text(query, 1)
            result.append(ClipRepresentation(item: Int(sqlite3_column_int(query, 0)), type: type, data: data))
        }
        guard !result.isEmpty else { throw LibraryError.missingContent }
        return result
    }

    /// 原始纯文本 / URL 优先；RTF 共享 256 KiB 解析预算，超限明确失败，绝不返回截断粘贴。
    func plainText(_ id: UUID, kind: ClipKind) async throws -> [ClipRepresentation] {
        guard kind == .text || kind == .link else { throw LibraryError.unsupported }
        let originals = try await representations(id)
        let indices = Set(originals.map(\.item)).sorted()
        var parts: [String] = []
        var bytes = 0
        var richTextBudget = ClipboardFormats.maximumRichTextPreviewBytes
        for index in indices {
            let items = originals.filter { $0.item == index }
            let types = kind == .link ? ["public.url", "public.utf8-plain-text"] : ["public.utf8-plain-text", "public.url"]
            var value: String?
            for type in types {
                if let item = items.first(where: { $0.type == type }), let text = String(data: item.data, encoding: .utf8) {
                    value = text
                    break
                }
            }
            if value == nil, let rtf = items.first(where: { $0.type == "public.rtf" }) {
                guard rtf.data.count <= richTextBudget else { throw LibraryError.richTextTooLarge }
                richTextBudget -= rtf.data.count
                value = try NSAttributedString(data: rtf.data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
            }
            guard let value else { throw LibraryError.plainTextUnavailable }
            bytes += value.utf8.count + (parts.isEmpty ? 0 : 1)
            guard bytes <= StorageLimits.maximumCaptureBytes else { throw LibraryError.unsupported }
            parts.append(value)
        }
        let data = Data(parts.joined(separator: "\n").utf8)
        guard !data.isEmpty else { throw LibraryError.plainTextUnavailable }
        return [ClipRepresentation(item: 0, type: "public.utf8-plain-text", data: data)]
    }

    /// 整条详情共享 16 KB 文本 / 256 KiB RTF 预算；420px 与列表 640px 共用同一有界缓存。
    func preview(_ id: UUID) async throws -> ClipPreview {
        try Task.checkCancellation()
        try prepare()
        var preview = ""
        var textItems: Set<Int> = []
        var richTextBudget = ClipboardFormats.maximumRichTextPreviewBytes
        var truncated = false
        var storedThumbnail: URL?
        var referencedThumbnail: URL?
        let textBudget = 16_000
        do {
            let query = try statement("""
                SELECT uti,filename,item_order FROM representation WHERE entry_id=?
                ORDER BY item_order,CASE uti WHEN 'public.file-url' THEN 0
                    WHEN 'public.utf8-plain-text' THEN 1 WHEN 'public.url' THEN 2
                    WHEN 'public.rtf' THEN 3 ELSE 4 END,id
                """, [.text(id.uuidString)])
            defer { sqlite3_finalize(query) }
            while try next(query) {
                try Task.checkCancellation()
                let type = text(query, 0)
                let item = Int(sqlite3_column_int(query, 2))
                let name = text(query, 1)
                guard let url = assetURL(name) else { throw LibraryError.storage }
                if ClipboardFormats.rasterImages.contains(type) {
                    if storedThumbnail == nil { storedThumbnail = url }
                } else if type == "public.file-url", referencedThumbnail == nil { referencedThumbnail = url }
                if !textItems.contains(item) {
                    let separator = preview.isEmpty ? "" : "\n"
                    let remaining = textBudget - preview.utf8.count - separator.utf8.count
                    var value: String?
                    if type == "public.file-url" {
                        if let data = try? assetData(name, maximum: 16_385), data.count <= 16_384,
                           let raw = String(data: data, encoding: .utf8),
                           let reference = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), reference.isFileURL {
                            value = reference.lastPathComponent
                        }
                    } else if ["public.utf8-plain-text", "public.url"].contains(type) {
                        // 额外读取最多一个 scalar，不能把读取边界切断的有效 UTF-8 误判为损坏数据。
                        if let data = try? assetData(name, maximum: max(4, remaining + 4)), !data.isEmpty {
                            value = BoundedText.decode(data, maximumBytes: max(0, remaining))
                            if data.count > max(0, remaining) { truncated = true }
                        }
                    } else if type == "public.rtf", let data = try? assetData(name, maximum: richTextBudget + 1), data.count <= richTextBudget {
                        richTextBudget -= data.count
                        value = ClipboardFormats.richText(data, maximumBytes: max(4, remaining + 4), maximumCharacters: nil)
                        if let value, value.utf8.count > max(0, remaining) { truncated = true }
                    }
                    if let value, !value.isEmpty {
                        textItems.insert(item)
                        if remaining > 0 {
                            let bounded = BoundedText.prefix(value, maximumBytes: remaining)
                            preview += separator + bounded
                            if bounded != value { truncated = true }
                        } else { truncated = true }
                    }
                }
            }
        }
        try Task.checkCancellation()
        let generation = thumbnailCache.generation
        let source = storedThumbnail.map(ThumbnailSource.stored) ?? referencedThumbnail.map(ThumbnailSource.referenced)
        let thumbnail = await requestedThumbnail(id, source: source, maximum: 420)
        try Task.checkCancellation()
        guard generation == thumbnailCache.generation else { return ClipPreview(text: "", thumbnail: nil) }
        if truncated { preview += "\n…预览已截断，复制保留原始内容" }
        return ClipPreview(text: preview, thumbnail: thumbnail)
    }
}
