/**
 * 存储 actor 内的有界缩略图像素缓存：按插入顺序淘汰，删除 / 清空通过代数拒绝过期解码结果。
 * @author helele
 * @since 2026-11-09
 */
import Foundation

/// 只缓存应用自己保存的像素表示，不长期复用可能被外部应用替换的文件引用。
struct ThumbnailCache {
    struct Key: Hashable {
        let id: UUID
        let maximum: Int
    }

    /// 单张缩略图与总量上限；420 / 640 px 两种尺寸共用同一预算。
    static let maximumEntries = 24
    static let maximumBytes = 2 * 1024 * 1024
    /// 同时挂起的请求上限，避免形成无限等待队列。
    static let maximumActiveRequests = 12

    /// 挂起期间发生删除 / 清空 / 自动回收时递增，调用者据此丢弃旧解码结果。
    private(set) var generation: UInt64 = 0
    var activeRequests = 0
    private var entries: [Key: Data] = [:]
    private var order: [Key] = []
    private var bytes = 0

    func data(for key: Key) -> Data? { entries[key] }

    /// 多个等待者可能先后写入同一键，已存在时直接复用，避免重复计入顺序和字节数。
    mutating func store(_ data: Data, for key: Key) -> Data {
        if let cached = entries[key] { return cached }
        while !order.isEmpty && (order.count >= Self.maximumEntries || bytes + data.count > Self.maximumBytes) {
            if let old = entries.removeValue(forKey: order.removeFirst()) { bytes -= old.count }
        }
        entries[key] = data
        order.append(key)
        bytes += data.count
        return data
    }

    mutating func invalidate(_ id: UUID) {
        generation &+= 1
        for key in order where key.id == id {
            if let old = entries.removeValue(forKey: key) { bytes -= old.count }
        }
        order.removeAll { $0.id == id }
    }

    mutating func removeAll() {
        generation &+= 1
        entries.removeAll()
        order.removeAll()
        bytes = 0
    }
}
