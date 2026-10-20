/**
 * 来源应用身份解析：按 Bundle ID 缓存名称与 20 pt 图标，不扫描应用目录。
 * @author helele
 * @since 2026-10-19
 */
import AppKit
import SwiftUI

/// 通过 Bundle ID 解析本机应用，身份缺失时使用系统通用符号。
struct SourceAppIcon: View {
    /// 采集时保存的来源标识，不通过显示名称推断同名应用。
    let bundleID: String
    /// 列表使用 12 pt，设置行使用 20 pt；缓存图按显示尺寸缩放。
    var dimension: CGFloat = 12
    /// 当前行只保留一张小图；SwiftUI 回收行时释放引用。
    @ViewState<NSImage?> private var image = nil

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit()
            }
        }
        .frame(width: dimension, height: dimension)
        .accessibilityHidden(true)
        .task(id: bundleID) {
            image = nil
            // 先让出执行机会；任务已取消的行不再查询图标，但不保证首帧已经提交。
            await Task.yield()
            guard !Task.isCancelled, !bundleID.isEmpty else { return }
            image = ApplicationDirectory.shared.icon(for: bundleID)
        }
    }
}

/// 设置页和添加菜单共用的一条应用身份；图标仅为栅格化缩略图。
struct ApplicationInfo: Identifiable {
    /// 持久化使用的稳定 Bundle ID。
    let bundleID: String
    /// 优先使用系统本地化名称，找不到应用时回退到可读名称或 Bundle ID 尾段。
    let name: String
    /// 20 pt 缓存缩略图；未安装或无法解析时为 nil。
    let icon: NSImage?
    var id: String { bundleID }
}

/// NSWorkspace 和绘制限制在主线程；每个应用只查一次，缺失结果也进入有界缓存。
@MainActor
final class ApplicationDirectory {
    static let shared = ApplicationDirectory()
    /// 最多保存 64 个应用身份；图标与名称一起缓存，避免每行重复访问文件系统。
    private let cache = NSCache<NSString, CachedEntry>()
    /// 未安装时仍能显示可读名称的内置默认项，不根据同名应用猜测其他身份。
    private let fallbackNames = [
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.apple.Passwords": "密码"
    ]

    private init() {
        cache.countLimit = 64
        cache.totalCostLimit = 768 * 1024
    }

    /// 设置行需要的完整身份；缓存命中时不访问 NSWorkspace。
    func info(for bundleID: String) -> ApplicationInfo {
        let entry = entry(for: bundleID)
        return ApplicationInfo(bundleID: bundleID, name: entry.name, icon: entry.icon)
    }

    func icon(for bundleID: String) -> NSImage? {
        entry(for: bundleID).icon
    }

    func displayName(for bundleID: String) -> String {
        entry(for: bundleID).name
    }

    /// 仅列出普通前台应用，去重后按本地化名称排序；排除项和本应用不进入菜单。
    func runningApplications(excluding excluded: Set<String>) -> [ApplicationInfo] {
        let ownBundleID = Bundle.main.bundleIdentifier
        let excludedLowercased = Set(excluded.map { $0.lowercased() })
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application -> ApplicationInfo? in
                guard let bundleID = application.bundleIdentifier,
                      bundleID != ownBundleID,
                      !excludedLowercased.contains(bundleID.lowercased()),
                      seen.insert(bundleID).inserted else { return nil }
                let entry = entry(for: bundleID)
                return ApplicationInfo(bundleID: bundleID,
                                       name: application.localizedName ?? entry.name,
                                       icon: entry.icon)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 先按 Bundle ID 查找应用；找不到时保留用户输入，设置页仍可展示与移除。
    private func entry(for bundleID: String) -> CachedEntry {
        let key = bundleID as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name: String
        let icon: NSImage?
        if let url {
            let bundle = Bundle(url: url)
            name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            icon = rasterizedIcon(for: url)
        } else {
            name = fallbackNames[bundleID]
                ?? bundleID.split(separator: ".").last.map(String.init)
                ?? bundleID
            icon = nil
        }
        let entry = CachedEntry(name: name, icon: icon)
        cache.setObject(entry, forKey: key, cost: icon == nil ? 1 : 8 * 1024)
        return entry
    }

    /// 显式栅格化到 Retina 40 px，列表缩到 12 pt、设置行缩到 20 pt 时仍保持清晰。
    private func rasterizedIcon(for url: URL) -> NSImage? {
        let original = NSWorkspace.shared.icon(forFile: url.path)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        original.draw(in: NSRect(x: 0, y: 0, width: 40, height: 40), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.addRepresentation(bitmap)
        return image
    }
}

/// 名称与图标一起缓存，避免设置页每行分别查询系统服务。
private final class CachedEntry {
    let name: String
    let icon: NSImage?

    init(name: String, icon: NSImage?) {
        self.name = name
        self.icon = icon
    }
}
