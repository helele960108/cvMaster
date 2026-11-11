/**
 * 缩略图请求编排：缓存命中、并发等待者上限、BUSY 有界重试，以及代数校验。
 * @author helele
 * @since 2026-11-09
 */
import Foundation
import SQLite3

extension HistoryStore {
    func thumbnail(_ id: UUID) async throws -> Data? {
        try Task.checkCancellation()
        try prepare()
        let sources = try thumbnailSources(id)
        let source = sources.stored.map(ThumbnailSource.stored) ?? sources.referenced.map(ThumbnailSource.referenced)
        return await requestedThumbnail(id, source: source, maximum: 640)
    }

    /// 最多 12 个活跃等待者；只有 BUSY 重试两次，失败 / 超时不重试，不积累无限等待队列。
    func requestedThumbnail(_ id: UUID, source: ThumbnailSource?, maximum: Int) async -> Data? {
        guard let source, !Task.isCancelled else { return nil }
        let usesReference: Bool
        if case .referenced = source { usesReference = true } else { usesReference = false }
        let key = ThumbnailCache.Key(id: id, maximum: maximum)
        if !usesReference, let cached = thumbnailCache.data(for: key) { return cached }
        guard thumbnailCache.activeRequests < ThumbnailCache.maximumActiveRequests else { return nil }
        thumbnailCache.activeRequests += 1
        defer { thumbnailCache.activeRequests -= 1 }
        let generation = thumbnailCache.generation
        for attempt in 0..<3 {
            guard !Task.isCancelled, generation == thumbnailCache.generation else { return nil }
            let result = await ThumbnailPipeline.shared.thumbnailResult(source, maximum: maximum)
            guard !Task.isCancelled, generation == thumbnailCache.generation else { return nil }
            switch result {
            case .unavailable: return nil
            case .busy:
                guard attempt < 2 else { return nil }
                do { try await Task.sleep(for: .milliseconds(attempt == 0 ? 80 : 160)) }
                catch { return nil }
            case .image(let data):
                guard data.count <= ThumbnailCache.maximumBytes else { return nil }
                return usesReference ? data : thumbnailCache.store(data, for: key)
            }
        }
        return nil
    }

    func thumbnailSources(_ id: UUID) throws -> (stored: URL?, referenced: URL?) {
        let query = try statement("SELECT uti,filename FROM representation WHERE entry_id=? ORDER BY item_order,id", [.text(id.uuidString)])
        defer { sqlite3_finalize(query) }
        var stored: URL?
        var referenced: URL?
        while try next(query) {
            try Task.checkCancellation()
            let type = text(query, 0)
            guard let url = assetURL(text(query, 1)) else { throw LibraryError.storage }
            if ClipboardFormats.rasterImages.contains(type) {
                if stored == nil { stored = url }
            } else if type == "public.file-url", referenced == nil { referenced = url }
        }
        return (stored, referenced)
    }
}
