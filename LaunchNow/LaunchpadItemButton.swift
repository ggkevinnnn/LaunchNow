import SwiftUI
import AppKit
// Shared animations

struct LaunchpadItemButton: View {
    let item: LaunchpadItem
    let iconSize: CGFloat
    let labelWidth: CGFloat
    let isSelected: Bool
    let showAppNameBelowIcon: Bool
    var shouldAllowHover: Bool = true
    var externalScale: CGFloat? = nil
    let onTap: () -> Void
    let onDoubleClick: (() -> Void)?
    
    @State private var isHovered = false
    @State private var lastTapTime = Date.distantPast
    private let doubleTapThreshold: TimeInterval = 0.3
    
    private var effectiveScale: CGFloat {
        if let s = externalScale { return s }
        return (isHovered && shouldAllowHover) ? 1.2 : 1.0
    }
    
    private var isFolderIcon: Bool {
        if case .folder = item { return true }
        return false
    }

    // Memoized icon to avoid recomputing on every body invocation
    @inline(__always)
    private func resolveIcon() -> NSImage {
        switch item {
        case .app(let app):
            // 尝试从缓存获取图标
            if let cachedIcon = AppCacheManager.shared.getCachedIcon(for: app.url.path),
               cachedIcon.size.width > 0, cachedIcon.size.height > 0 {
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
    }

    init(
        item: LaunchpadItem,
        iconSize: CGFloat = 72,
        labelWidth: CGFloat = 80,
        isSelected: Bool = false,
        showAppNameBelowIcon: Bool = true,
        shouldAllowHover: Bool = true,
        externalScale: CGFloat? = nil,
        isAnimating: Bool = false,
        onTap: @escaping () -> Void,
        onDoubleClick: (() -> Void)? = nil) {
            self.item = item
            self.iconSize = iconSize
            self.labelWidth = labelWidth
            self.isSelected = isSelected
            self.showAppNameBelowIcon = showAppNameBelowIcon
            self.shouldAllowHover = shouldAllowHover
            self.externalScale = externalScale
            self.onTap = onTap
            self.onDoubleClick = onDoubleClick
        }

    var body: some View {
        let renderedIcon = resolveIcon()
        return Button(action: handleTap) {
            VStack(spacing: 8) {
                ZStack {
                    if isFolderIcon {   
                        RoundedRectangle(cornerRadius: iconSize * 0.2)
                            .foregroundStyle(Color.clear)
                            .frame(width: iconSize * 0.8, height: iconSize * 0.8)
                            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: iconSize * 0.2))
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
                }
                .contentShape(Rectangle())
                .scaleEffect(isSelected ? 1.2 : effectiveScale)
                .animation(LNAnimations.easeInOut, value: isHovered || isSelected)

                if showAppNameBelowIcon {
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
            if shouldAllowHover {
                isHovered = hovering
            } else if isHovered {
                isHovered = false
            }
        }
        .onChange(of: shouldAllowHover) {
            if !shouldAllowHover, isHovered {
                isHovered = false
            }
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

// Equatable conformance intentionally excludes closures (onTap, onDoubleClick).
// This allows SwiftUI to skip body re-evaluation when only scroll offset changes,
// while still re-rendering when any visible property actually changes.
extension LaunchpadItemButton: Equatable {
    private static func isVisuallySameItem(_ lhs: LaunchpadItem, _ rhs: LaunchpadItem) -> Bool {
        switch (lhs, rhs) {
        case let (.app(lApp), .app(rApp)):
            return lApp.id == rApp.id
        case let (.folder(lFolder), .folder(rFolder)):
            // Folder icon and title depend on folder name + contained apps.
            return lFolder.id == rFolder.id &&
                lFolder.name == rFolder.name &&
                lFolder.apps.map(\.id) == rFolder.apps.map(\.id)
        case let (.empty(lToken), .empty(rToken)):
            return lToken == rToken
        default:
            return false
        }
    }

    static func == (lhs: LaunchpadItemButton, rhs: LaunchpadItemButton) -> Bool {
        isVisuallySameItem(lhs.item, rhs.item) &&
        lhs.iconSize == rhs.iconSize &&
        lhs.labelWidth == rhs.labelWidth &&
        lhs.isSelected == rhs.isSelected &&
        lhs.showAppNameBelowIcon == rhs.showAppNameBelowIcon &&
        lhs.shouldAllowHover == rhs.shouldAllowHover &&
        lhs.externalScale == rhs.externalScale
    }
}
