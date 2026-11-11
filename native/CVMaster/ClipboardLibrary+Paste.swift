/**
 * 再次复制与粘贴：先后台准备完整表示，目标校验通过后才改写系统剪贴板。
 * @author helele
 * @since 2026-11-09
 */
import AppKit

@MainActor
extension ClipboardLibrary {
    /// 粘贴前校验目标并后台读取原始表示，准备成功后才清空剪贴板；自写 changeCount 由监测器跳过。
    /// plainText 为 true 时仅对文本 / 链接生效，转换完成后才写回系统剪贴板。
    func paste(_ clip: Clip, plainText: Bool = false) {
        guard !copying, !loading else { return }
        guard !plainText || clip.kind == .text || clip.kind == .link else { return }
        do {
            guard let validatePasteTarget, preparePasteTarget != nil, performPaste != nil else { throw LibraryError.pasteTargetUnavailable }
            try validatePasteTarget()
        } catch { report(error); return }
        copying = true
        Task { [weak self, store] in
            do {
                let representations: [ClipRepresentation]
                if plainText { representations = try await store.plainText(clip.id, kind: clip.kind) }
                else { representations = try await store.representations(clip.id) }
                guard let self else { return }
                var items: [Int: NSPasteboardItem] = [:]
                for representation in representations {
                    let item = items[representation.item] ?? NSPasteboardItem()
                    // 写入临时 item 失败时不清空系统剪贴板，避免返回不完整的多格式内容。
                    guard item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type)) else {
                        throw LibraryError.missingContent
                    }
                    items[representation.item] = item
                }
                guard let preparePasteTarget = self.preparePasteTarget else { throw LibraryError.pasteTargetUnavailable }
                try await preparePasteTarget()
                // 深度检查包含挂起点，写入前再次检查权限与交接状态，中间不再 await。
                guard let validatePasteTarget = self.validatePasteTarget else { throw LibraryError.pasteTargetUnavailable }
                try validatePasteTarget()
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.writeObjects(items.keys.sorted().compactMap { items[$0] }) else {
                    self.monitor?.resetBaseline(); throw LibraryError.missingContent
                }
                self.monitor?.resetBaseline()
                // 读取期间目标可能已关闭；原生层重新校验，失败不会向其他窗口发送内容。
                guard let performPaste = self.performPaste else { throw LibraryError.pasteTargetUnavailable }
                try await performPaste()
                self.copying = false
                // 仅在粘贴事件已发送后记录使用次数，不把写入剪贴板当作粘贴成功。
                do { try await store.markCopied(clip.id) }
                catch { self.report(error) }
            } catch { self?.copying = false; self?.report(error) }
        }
    }
}
