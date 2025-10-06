import SwiftUI
import AppKit
// Shared animations

struct LaunchpadItemButton: View {
    let item: LaunchpadItem
    let iconSize: CGFloat
    let labelWidth: CGFloat
    let isSelected: Bool
    var shouldAllowHover: Bool = true
    var externalScale: CGFloat? = nil
    let onTap: () -> Void
    let onDoubleClick: (() -> Void)?
    
    @EnvironmentObject var appStore: AppStore
    
    @State private var isHovered = false
    @State private var lastTapTime = Date.distantPast
    @State private var forceRefreshTrigger: UUID = UUID()
    private let doubleTapThreshold: TimeInterval = 0.3
    
    private var effectiveScale: CGFloat {
        if let s = externalScale { return s }
        return (isHovered && shouldAllowHover) ? 1.2 : 1.0
    }
    
    private var isFolderIcon: Bool {
        if case .folder = item { return true }
        return false
    }
    
    init(item: LaunchpadItem,
         iconSize: CGFloat = 72,
         labelWidth: CGFloat = 80,
         isSelected: Bool = false,
          shouldAllowHover: Bool = true,
          externalScale: CGFloat? = nil,
         onTap: @escaping () -> Void,
         onDoubleClick: (() -> Void)? = nil) {
        self.item = item
        self.iconSize = iconSize
        self.labelWidth = labelWidth
        self.isSelected = isSelected
        self.shouldAllowHover = shouldAllowHover
        self.externalScale = externalScale
        self.onTap = onTap
        self.onDoubleClick = onDoubleClick
    }

    var body: some View {
        Button(action: handleTap) {
            VStack(spacing: 8) {
                ZStack {
                    let renderedIcon: NSImage = {
                        switch item {
                        case .app(let app):
                            // 尝试从缓存获取图标
                            if let cachedIcon = AppCacheManager.shared.getCachedIcon(for: app.url.path), cachedIcon.size.width > 0, cachedIcon.size.height > 0 {
                                return cachedIcon
                            }
                            // 使用自身图标或兜底到系统图标
                            let base = app.icon
                            if base.size.width > 0 && base.size.height > 0 {
                                return base
                            } else {
                                return NSWorkspace.shared.icon(forFile: app.url.path)
                            }
                        case .folder(let folder):
                            return folder.icon(of: iconSize)
                        case .empty:
                            return item.icon
                        }
                    }()
                    
                    if isFolderIcon {
                        // 增加文件夹的检测区域，使用更大的响应区域
                        RoundedRectangle(cornerRadius: iconSize * 0.2)
                            .foregroundStyle(Color.clear)
                            .frame(width: iconSize * 0.8, height: iconSize * 0.8)
                            .glassEffect(in: RoundedRectangle(cornerRadius: iconSize * 0.2))
                            .shadow(radius: 3)
                            .overlay(
                                RoundedRectangle(cornerRadius: iconSize * 0.2)
                                    .stroke(Color.foundary.opacity(0.5), lineWidth: 2)
                            )
                    }
                    
                    Image(nsImage: renderedIcon)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .frame(width: iconSize, height: iconSize)
                        .id(item.id + "_" + forceRefreshTrigger.uuidString) // 使用组合ID强制刷新，确保文件夹图标能够正确更新
                }
                .contentShape(Rectangle()) // 确保整个区域可以接收事件
                .scaleEffect(isSelected ? 1.2 : effectiveScale)
                .animation(LNAnimations.springFast, value: isHovered || isSelected) // 为文件夹添加轻微延迟，防止过早移动

                if appStore.showAppNameBelowIcon {
                    Text(item.name)
                        .font(.default)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .truncationMode(.tail)
                        .frame(width: labelWidth)
                        .foregroundStyle(.primary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(8)
        .onHover { hovering in
            isHovered = hovering
        }
    }
    
    private func handleTap() {
        let now = Date()
        let timeSinceLastTap = now.timeIntervalSince(lastTapTime)
        
        if timeSinceLastTap <= doubleTapThreshold, let doubleClick = onDoubleClick {
            // 双击
            doubleClick()
        } else {
            // 单击
            onTap()
        }
        
        lastTapTime = now
    }
}
