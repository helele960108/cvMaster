/**
 * 侧图微卡片：正文优先、来源沉底，图片使用受控后台缩略图，不持有原图。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
import SwiftUI

struct ClipCardContent: View {
    /// 共享内容服务，仅在可见图片卡片请求小缩略图。
    let library: ClipboardLibrary
    /// 轻量记录投影，正文摘要已在存储层截断。
    let clip: Clip
    /// 当前卡片的小图，退出可见区域时释放。
    @ViewState<NSImage?> private var thumbnail = nil

    var body: some View {
        Group {
            if clip.showsImage {
                VStack(spacing: 0) {
                    imageCard
                    metadata.padding(.horizontal, 13).padding(.vertical, 11)
                }
            } else {
                details
            }
        }
        .task(id: clip.id) {
            guard clip.showsImage else { return }
            // 首帧使用占位，任务取消后不向已回收卡片交付图像。
            let data = await library.thumbnail(clip.id)
            guard !Task.isCancelled else { return }
            thumbnail = data.flatMap { NSImage(data: $0) }
        }
        .onDisappear { thumbnail = nil }
    }

    /// 图片铺满卡片上部，底部信息独立展示；固定高度避免加载完成时列表跳动。
    private var imageCard: some View {
        Color(nsColor: .controlBackgroundColor)
            .frame(height: 160)
            .overlay {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo").font(.title2)
                        if clip.isImageFile {
                            Text(clip.title).font(.caption).lineLimit(2)
                            Text("原文件不可用或格式不支持时无法预览").font(.caption2)
                        }
                    }.foregroundStyle(.secondary).padding(12)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .accessibilityLabel("图片，来自\(clip.source)，悬停查看详情")
    }

    /// 非图片记录维持正文优先、来源沉底的紧凑布局。
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if clip.kind == .file {
                    attachment
                }
                VStack(alignment: .leading, spacing: 5) {
                    if clip.kind == .file {
                        filename
                    } else {
                        // 使用完整的有界摘要而非截短标题，统一字号以充分利用内容区域。
                        Text(contentText)
                            .font(.callout.weight(.medium)).foregroundStyle(.primary)
                            .lineLimit(4).truncationMode(.tail).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if clip.kind == .file {
                        Text(summary).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            metadata
        }
    }

    /// 所有内容类型共用底部信息，避免图片卡片遗漏来源、时间及置顶状态。
    private var metadata: some View {
        HStack(spacing: 4) {
            SourceAppIcon(bundleID: clip.sourceBundleID)
            Text(clip.source).lineLimit(1).truncationMode(.tail)
            Text("·")
            ClipRelativeTime(date: clip.copiedAt).fixedSize()
            Spacer(minLength: 4)
            if clip.pinned {
                Image(systemName: "pin.fill").foregroundStyle(ClipboardLibrary.accent)
                    .accessibilityLabel("已置顶")
            }
            Image(systemName: clip.kind.symbol)
                .accessibilityLabel("类型：\(clip.kind.rawValue)")
        }
        .font(.caption2).foregroundStyle(.secondary)
        .help("来源应用：\(clip.source)（推断） · \(clip.kind.rawValue)")
    }

    /// 列表沿用存储层的 240 字符预算，已到摘要上限时明确标记还有更多内容。
    private var contentText: String {
        let text = clip.excerpt.isEmpty ? clip.title : clip.excerpt
        return clip.excerpt.count >= 240 ? text + "…" : text
    }

    /// 图片与文件显示存储表示大小，不把引用大小误写为原文件体积。
    private var summary: String {
        "文件引用 · \(clip.size)"
    }

    /// 文件主体允许三行，后缀单独保留，不随长文件名一起被尾部截掉。
    /// 优先从文件名摘要取首个真实名称，避免多文件标题的“等 N 个文件”被当成后缀。
    private var filename: some View {
        let name = clip.title.hasSuffix("个文件")
            ? (clip.excerpt.split(separator: "\n").first.map(String.init) ?? clip.title)
            : clip.title
        let ext = (name as NSString).pathExtension
        let hasExtension = !ext.isEmpty
        let stem = hasExtension ? (name as NSString).deletingPathExtension : name
        return HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text(stem).lineLimit(3).truncationMode(.tail)
                .layoutPriority(0)
            if hasExtension {
                Text(".\(ext)").lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
        .font(.callout.weight(.medium)).foregroundStyle(.primary)
        .multilineTextAlignment(.leading)
        .help(name)
        .accessibilityLabel(name)
    }

    private var attachment: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
                    .overlay {
                        Image(systemName: clip.kind.symbol).font(.title3)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: clip.kind == .image ? 68 : 44, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(clip.kind == .image ? "图片缩略图" : "文件引用")
    }
}
