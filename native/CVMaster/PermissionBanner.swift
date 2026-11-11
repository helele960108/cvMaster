/**
 * 缺少辅助功能权限时的情境式引导横幅：说明用途、直达系统设置，并允许本次运行内稍后处理。
 * @author helele
 * @since 2026-11-09
 */
import SwiftUI

struct PermissionBanner: View {
    @ObservedObject var library: ClipboardLibrary
    /// 仅在本次应用运行内有效，下次启动仍会提示。
    @Binding var dismissed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(ClipboardLibrary.accent)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("自动粘贴需要辅助功能权限")
                    .font(.caption.weight(.semibold))
                Text("授权后，回车或双击可直接粘贴到当前激活的 APP。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            Spacer(minLength: 4)
            Button("去开启") { library.openAccessibilitySettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("打开系统设置 → 隐私与安全性 → 辅助功能")
            Button { dismissed = true } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("稍后")
            .help("本次使用期间不再提示")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ClipboardLibrary.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(ClipboardLibrary.accent.opacity(0.25), lineWidth: 1)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}
