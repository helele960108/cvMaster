/**
 * 条目侧边的临时内容预览，不挤占主列表空间；数据仍按需加载且受大小预算约束。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
import SwiftUI

struct SidePreviewView: View {
    /// 共享加载状态和唯一预览缓冲，不创建第二份原始内容缓存。
    @ObservedObject var library: ClipboardLibrary
    /// 当前锚定条目的轻量元数据，不持有完整内容。
    let clip: Clip
    /// 只保留当前预览的一张图像，退出预览时释放局部引用。
    @ViewState<NSImage?> private var thumbnail = nil

    /// 同一条目的缩略图可能稍后才返回，必须同时比较实际结果，不能只按条目重启任务。
    private struct ThumbnailKey: Equatable {
        let clipID: UUID
        let data: Data?
    }

    /// 从最新投影读取置顶状态，避免操作后侧边按钮仍显示旧状态。
    private var pinned: Bool { library.clips.first { $0.id == clip.id }?.pinned ?? clip.pinned }

    var body: some View {
        let thumbnailKey = ThumbnailKey(clipID: clip.id, data: library.preview?.thumbnail)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if clip.showsImage {
                    // 图片预览以来源应用作为标题，不再重复展示类型图标和“图片”文字。
                    HStack(spacing: 5) {
                        SourceAppIcon(bundleID: clip.sourceBundleID)
                        Text(clip.source).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .help("来源应用：\(clip.source)（推断）")
                } else {
                    Label(clip.kind.rawValue, systemImage: clip.kind.symbol)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(pinned ? "取消置顶" : "置顶", systemImage: "pin") {
                    if let current = library.clips.first(where: { $0.id == clip.id }) { library.setPinned(current) }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(ClipboardLibrary.accent)
            }
            if clip.showsImage {
                Text(clip.time).font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if library.previewLoading { ProgressView().controlSize(.small) }
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit().frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityLabel("图片预览")
                    }
                    if clip.showsImage, !library.previewLoading, library.preview?.thumbnail == nil {
                        Label(clip.isImageFile ? "原文件不可用、超出预览限制或格式不支持" : "图片数据缺失或格式不支持",
                              systemImage: "photo.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // 图片预览仅保留图像与来源，不展示文件名或引用文本；普通文件显示安全文件名。
                    if !clip.showsImage {
                        Text(library.preview.flatMap { $0.text.isEmpty ? nil : $0.text } ?? clip.excerpt)
                            .font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                }
            }
            if !clip.showsImage {
                Text(clip.hasFileReference ? "包含文件引用，原文件需保持可用 · \(clip.size)" : "\(clip.size) · \(clip.copies) 次复制")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16).frame(width: 310, height: 300)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("内容预览")
        .task(id: thumbnailKey) {
            thumbnail = nil
            // 与卡片一致，取消的任务不交付图像；让出执行机会，不把 AppKit 绘制移出主线程。
            await Task.yield()
            guard !Task.isCancelled else { return }
            thumbnail = thumbnailKey.data.flatMap { NSImage(data: $0) }
        }
        .onDisappear { thumbnail = nil }
    }
}
