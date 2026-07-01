import SwiftUI
import AppKit

private enum FolderVisualSlot: Identifiable, Equatable {
    case app(AppInfo)
    case placeholder(String)

    var id: String {
        switch self {
        case .app(let app):
            return "app_\(app.id)"
        case .placeholder(let token):
            return "placeholder_\(token)"
        }
    }
}

struct FolderView: View {
    @ObservedObject var appStore: AppStore
    @Binding var folder: FolderInfo
    // 若提供，将强制使用与外层一致的图标尺寸
    var preferredIconSize: CGFloat? = nil
    // 控制是否延迟显示网格内容（等待图标加载完成）
    var deferGridUntilOpened: Bool = true
    @State private var folderName: String = ""
    @State private var isEditingName = false
    @FocusState private var isTextFieldFocused: Bool
    @Namespace private var reorderNamespaceFolder
    // 键盘导航
    @State private var selectedIndex: Int? = nil
    @State private var isKeyboardNavigationActive: Bool = false
    @State private var keyMonitor: Any?
    // 拖拽相关状态
    @State private var draggingApp: AppInfo? = nil
    @State private var dragPreviewPosition: CGPoint = .zero
    @State private var dragPreviewScale: CGFloat = 1.2
    @State private var dragPreviewOpacity: Double = 1.0
    @State private var isSettlingDrop: Bool = false
    @State private var pendingDropIndex: Int? = nil
    @State private var dragSourceApps: [AppInfo]? = nil
    @State private var scrollOffsetY: CGFloat = 0
    @State private var outOfBoundsBeganAt: Date? = nil
    @State private var hasHandedOffDrag: Bool = false
    @State private var lastDroppedAppID: String? = nil
    @State private var isScrolling: Bool = false
    @State private var lastScrollMark: Date = .distantPast
    @State private var isDraggingActive: Bool = false
    private let autoScrollZoneSize: CGFloat = 40
    private let autoScrollStep: CGFloat = 6
    private let outOfBoundsDwell: TimeInterval = 0.0
    // NSEvent 级别拖拽
    @State private var folderDragEventMonitor: Any? = nil
    @State private var folderDragMouseDownApp: AppInfo? = nil
    @State private var folderDragMouseDownLocation: CGPoint = .zero
    @State private var folderGridOriginInWindow: CGPoint = .zero
    @State private var folderCurrentContainerSize: CGSize = .zero
    @State private var folderCurrentColumnWidth: CGFloat = 0
    @State private var folderCurrentAppHeight: CGFloat = 0
    @State private var folderCurrentIconSize: CGFloat = 0
    @State private var folderClipView: NSClipView? = nil
    
    let onClose: () -> Void
    let onLaunchApp: (AppInfo) -> Void
    
    // 优化间距和布局参数
    private let spacing: CGFloat = 30
    // 动态列数，根据窗口宽度与单元最小宽度自适应
    @State private var columnsCount: Int = 4
    private let gridPadding: CGFloat = 16
    private let titlePadding: CGFloat = 16

    private var visualApps: [AppInfo] {
        visualAppSlots.compactMap {
            if case .app(let app) = $0 { return app }
            return nil
        }
    }

    private var visualAppSlots: [FolderVisualSlot] {
        let sourceApps = dragSourceApps ?? folder.apps
        guard let dragging = draggingApp, let pending = pendingDropIndex else {
            return sourceApps.map(FolderVisualSlot.app)
        }
        var slots = sourceApps.map(FolderVisualSlot.app)
        if let from = slots.firstIndex(where: {
            if case .app(let app) = $0 {
                return app == dragging
            }
            return false
        }) {
            slots.remove(at: from)
            let insertIndex = pending
            let clamped = min(max(0, insertIndex), slots.count)
            slots.insert(.placeholder(dragging.id), at: clamped)
        }
        return slots
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 优化的文件夹标题区域
            folderTitleSection
            
            // 应用网格区域
            GeometryReader { geo in
                if deferGridUntilOpened {
                    // 轻量占位，避免在打开瞬间进行大量布局与图片绘制
                    // 文件夹窗口已显示，但等待图标加载完成
                    ZStack {
                        Color.clear
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    appGridSection(geometry: geo)
                }
            }
        }
        .padding(.horizontal)
        .background {
            if appStore.isGlasseffectEnabled {
                Color.clear.background(.ultraThinMaterial.opacity(appStore.materialOpacity), in: RoundedRectangle(cornerRadius: 30)).shadow(radius: 15)
                Color.clear.glassEffect(.clear, in: RoundedRectangle(cornerRadius: 30))
            } else {
                Color.clear.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30)).shadow(radius: 15)
            }
        }
        .onTapGesture {
            // 当点击文件夹视图的非编辑区域时，如果正在编辑名称，则退出编辑模式
            if isEditingName {
                finishEditing()
            }
        }
        .onAppear {
            folderName = folder.name
            setupKeyHandlers()
            setupInitialSelection()
            setupFolderDragMonitor()
            cacheFolderClipView()
            // 如果是通过回车键打开的文件夹，则自动启用导航并选中第一项
            if appStore.openFolderActivatedByKeyboard {
                isKeyboardNavigationActive = true
                setSelectionToStart()
                appStore.openFolderActivatedByKeyboard = false
            } else {
                isKeyboardNavigationActive = false
            }
            // deferGridUntilOpened 由外层 LaunchpadView 的 isFolderContentReady 控制
            // 不再在 onAppear 中自动设置为 false，避免图标未加载完成就显示网格
        }
        .onChange(of: isTextFieldFocused) { focused in
            if !focused && isEditingName {
                finishEditing()
            }
        }
        .onChange(of: folder.apps) {
            clampSelection()
        }
        .onChange(of: folder.name) {
            // 监听文件夹名称变化，确保界面立即更新
            if !isEditingName {
                folderName = folder.name
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
            if let monitor = folderDragEventMonitor {
                NSEvent.removeMonitor(monitor)
                folderDragEventMonitor = nil
            }
        }
    }
    
    @ViewBuilder
    private var folderTitleSection: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                if isEditingName {
                    TextField(NSLocalizedString("FolderName", comment: "Folder Name"), text: $folderName)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(.title)
                        .foregroundColor(.primary)
                        .focused($isTextFieldFocused)
                        .padding()
                        .onSubmit {
                            finishEditing()
                        }
                        .onTapGesture(count: 2) {
                            finishEditing()
                        }
                        .onTapGesture {
                            finishEditing()
                        }
                } else {
                    Text(folder.name)
                        .font(.title)
                        .foregroundColor(.primary)
                        .padding()
                        .contentShape(Rectangle()) // 确保整个区域都可以点击
                        .onTapGesture(count: 2) {
                            startEditing()
                        }
                        .onTapGesture {
                            // 单击时不做任何操作，避免意外触发
                        }
                }
            }
            Spacer()
        }
        .padding(.horizontal, titlePadding)
    }
    
    @ViewBuilder
    private func appGridSection(geometry geo: GeometryProxy) -> some View {
        // 固定为 6 列
        let desiredColumns = 6
        let computedIconBase = min(
            computeColumnWidth(containerWidth: geo.size.width, columns: desiredColumns),
            computeAppHeight(containerHeight: geo.size.height, columns: desiredColumns)
        ) * 0.75
        let iconSize: CGFloat = preferredIconSize ?? (computedIconBase * CGFloat(max(0.4, min(appStore.iconScale, 1.6))))
        // 使用自适应列数重新计算尺寸
        let recomputedColumnWidth = computeColumnWidth(containerWidth: geo.size.width, columns: desiredColumns)
        let recomputedAppHeight = computeAppHeight(containerHeight: geo.size.height, columns: desiredColumns)
        // 保障单元格至少能容纳传入的图标尺寸与标签区域
        let columnWidth = max(recomputedColumnWidth, iconSize)
        let appHeight = max(recomputedAppHeight, iconSize + 32)
        let labelWidth: CGFloat = columnWidth * 0.9
        let slots = visualAppSlots

        ZStack(alignment: .topLeading) {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: desiredColumns), spacing: spacing) {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                        if case .app(let app) = slot {
                            // 计算实际的应用索引（排除占位符）
                            let actualAppIndex = slots.prefix(index).filter { sl in
                                if case .app = sl { return true }
                                return false
                            }.count
                            appDraggable(
                                app: app,
                                containerSize: geo.size,
                                columnWidth: columnWidth,
                                appHeight: appHeight,
                                iconSize: iconSize,
                                labelWidth: labelWidth,
                                isSelected: isKeyboardNavigationActive && actualAppIndex == selectedIndex
                            )
                        } else {
                            Rectangle()
                                .fill(Color.clear)
                                .frame(height: appHeight)
                        }
                    }
                }
                .padding(EdgeInsets(top: gridPadding, leading: gridPadding, bottom: gridPadding, trailing: gridPadding))
                .background(GeometryReader { proxy in
                    let rawOriginY = proxy.frame(in: .named("folderGrid")).origin.y
                    let scrollOffset = gridPadding - rawOriginY
                    return Color.clear.preference(
                        key: FolderScrollOffsetPreferenceKey.self,
                        value: scrollOffset
                    )
                })
                .animation(LNAnimations.easeInOut, value: pendingDropIndex)
                .animation(LNAnimations.easeInOut, value: folder.apps)
                .animation(LNAnimations.easeInOut, value: selectedIndex)
            }
            .scrollIndicators(.hidden)
            .disabled(isEditingName) // 编辑状态下禁用滚动
            .onAppear { columnsCount = desiredColumns }
            .onChange(of: geo.size) {
                columnsCount = desiredColumns
            }

            // 拖拽预览层
            if let draggingApp {
                DragPreviewItem(item: .app(draggingApp),
                                iconSize: iconSize,
                                labelWidth: labelWidth,
                                scale: dragPreviewScale)
                    .position(x: dragPreviewPosition.x, y: dragPreviewPosition.y)
                    .opacity(dragPreviewOpacity)
                    .zIndex(100)
                    .allowsHitTesting(false)
                    .animation(LNAnimations.easeInOut, value: dragPreviewScale)
                    .animation(LNAnimations.easeInOut, value: dragPreviewOpacity)
            }
        }
        .coordinateSpace(name: "folderGrid")
        .overlay(
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                Color.clear
                    .onAppear {
                        folderGridOriginInWindow = origin
                        folderCurrentContainerSize = geo.size
                        folderCurrentColumnWidth = columnWidth
                        folderCurrentAppHeight = appHeight
                        folderCurrentIconSize = iconSize
                    }
                    .onChange(of: geo.size) { _, _ in
                        folderCurrentContainerSize = geo.size
                    }
                    .onChange(of: origin) { _, newOrigin in
                        folderGridOriginInWindow = newOrigin
                    }
                    .onChange(of: columnWidth) { _, newVal in folderCurrentColumnWidth = newVal }
                    .onChange(of: appHeight) { _, newVal in folderCurrentAppHeight = newVal }
                    .onChange(of: iconSize) { _, newVal in folderCurrentIconSize = newVal }
            }
        )
        .onPreferenceChange(FolderScrollOffsetPreferenceKey.self) { scrollOffset in
            guard !isDraggingActive else { return }
            scrollOffsetY = scrollOffset
            let now = Date()
            if now.timeIntervalSince(lastScrollMark) > 0.05 {
                lastScrollMark = now
                if !isScrolling { isScrolling = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    if Date().timeIntervalSince(lastScrollMark) > 0.1 {
                        isScrolling = false
                    }
                }
            }
        }
    }
    
    // 拖拽视觉重排
    
    private func startEditing() {
        isEditingName = true
        folderName = folder.name
        isTextFieldFocused = true
        appStore.isFolderNameEditing = true
    }
    
    private func finishEditing() {
        isEditingName = false
        appStore.isFolderNameEditing = false
        if !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let newName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            if newName != folder.name {
                appStore.renameFolder(folder, newName: newName)
            }
        } else {
            folderName = folder.name
        }
    }
    
}

// MARK: - Drag helpers & builders (mirror outer logic, without folder creation)
extension FolderView {
    private func computeAppHeight(containerHeight: CGFloat, columns: Int) -> CGFloat {
        // 自适应列数下估算行高
        let maxRowsPerPage = Int(ceil(Double(folder.apps.count) / Double(max(columns, 1))))
        let totalRowSpacing = spacing * CGFloat(max(0, maxRowsPerPage - 1))
        let height = (containerHeight - totalRowSpacing) / CGFloat(maxRowsPerPage == 0 ? 1 : maxRowsPerPage)
        return max(60, min(120, height)) // 优化高度范围
    }
    
    private func computeColumnWidth(containerWidth: CGFloat, columns: Int) -> CGFloat {
        let cols = max(columns, 1)
        let totalColumnSpacing = spacing * CGFloat(max(0, cols - 1))
        let width = (containerWidth - totalColumnSpacing) / CGFloat(cols)
        return max(50, width) // 优化最小宽度
    }

    // 拖拽命中与单元格几何计算（在下方扩展中实现）

    @ViewBuilder
    private func appDraggable(app: AppInfo,
                              containerSize: CGSize,
                              columnWidth: CGFloat,
                              appHeight: CGFloat,
                              iconSize: CGFloat,
                              labelWidth: CGFloat,
                              isSelected: Bool) -> some View {
        let isDraggingThisTile = (draggingApp == app)

        let base = LaunchpadItemButton(
            item: .app(app),
            iconSize: iconSize,
            labelWidth: labelWidth,
            isSelected: isSelected,
            showAppNameBelowIcon: appStore.showAppNameBelowIcon,
            shouldAllowHover: draggingApp == nil,
            onTap: {
                // 在编辑状态下不启动应用
                if draggingApp == nil && !isEditingName {
                    onLaunchApp(app)
                }
            }
        )
        .equatable()
        .frame(height: appHeight)
        // 保持稳定的视图身份，避免在文件夹更新后中断拖拽手势
        .id(app.id)

        withMatchedGeometry(base, id: app.id)
            // 淡入新放置的图标
            .opacity((lastDroppedAppID == app.id) ? 0 : 1)
            .animation(LNAnimations.easeInOut, value: lastDroppedAppID)
            // 拖拽时隐藏原始图标
            .opacity((isDraggingThisTile && !isSettlingDrop) ? 0 : 1)
            .animation(LNAnimations.easeInOut, value: isSettlingDrop)
            .allowsHitTesting(!isDraggingThisTile)
            .contentTransition(.opacity)
            .animation(LNAnimations.smooth, value: isSelected)
    }

    // MARK: - NSEvent 级别拖拽监听
    private func setupFolderDragMonitor() {
        if let existing = folderDragEventMonitor { NSEvent.removeMonitor(existing) }
        folderDragEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            switch event.type {
            case .leftMouseDown:
                guard !isEditingName, draggingApp == nil else { return event }
                refreshScrollOffset()
                let localPoint = convertWindowToFolderGrid(event.locationInWindow)
                if let idx = indexAt(point: localPoint, containerSize: folderCurrentContainerSize, columnWidth: folderCurrentColumnWidth, appHeight: folderCurrentAppHeight),
                   folder.apps.indices.contains(idx) {
                    folderDragMouseDownApp = folder.apps[idx]
                    folderDragMouseDownLocation = localPoint
                }
                return event

            case .leftMouseDragged:
                guard !isEditingName else { return event }
                refreshScrollOffset()
                let localPoint = convertWindowToFolderGrid(event.locationInWindow)

                if let dragging = draggingApp {
                    dragPreviewPosition = localPoint

                    // 自动滚动：拖拽到网格靠近顶部或底部边缘时触发
                    let scrollZoneTop = autoScrollZoneSize
                    let scrollZoneBottom = folderCurrentContainerSize.height - autoScrollZoneSize
                    if localPoint.y >= 0, localPoint.y <= folderCurrentContainerSize.height,
                       localPoint.y < scrollZoneTop || localPoint.y > scrollZoneBottom {
                        if let clipView = folderClipView ?? findFolderClipView(in: NSApp.keyWindow?.contentView) {
                            if folderClipView == nil { folderClipView = clipView }
                            let direction: CGFloat = localPoint.y < scrollZoneTop ? -1 : 1
                            // 计算可滚动范围
                            let appCount = (dragSourceApps ?? folder.apps).count
                            let totalRows = max(1, (appCount + columnsCount - 1) / columnsCount)
                            let contentHeight = gridPadding * 2 + CGFloat(totalRows) * folderCurrentAppHeight + CGFloat(max(0, totalRows - 1)) * spacing
                            let maxScrollOffset = max(0, contentHeight - folderCurrentContainerSize.height)
                            if maxScrollOffset > 0 {
                                var newOrigin = clipView.bounds.origin
                                newOrigin.y = max(0, min(maxScrollOffset, newOrigin.y + direction * autoScrollStep))
                                if newOrigin.y != clipView.bounds.origin.y {
                                    clipView.bounds.origin = newOrigin
                                    scrollOffsetY = newOrigin.y
                                }
                            }
                        }
                    }

                    let isOutside = localPoint.x < 0 || localPoint.y < 0 ||
                                    localPoint.x > folderCurrentContainerSize.width ||
                                    localPoint.y > folderCurrentContainerSize.height
                    let now = Date()
                    if isOutside {
                        if outOfBoundsBeganAt == nil { outOfBoundsBeganAt = now }
                        if !hasHandedOffDrag, let start = outOfBoundsBeganAt, now.timeIntervalSince(start) >= outOfBoundsDwell {
                            hasHandedOffDrag = true
                            pendingDropIndex = nil
                            appStore.handoffDraggingApp = dragging
                            if let window = NSApp.keyWindow {
                                appStore.handoffDragScreenLocation = window.convertPoint(toScreen: event.locationInWindow)
                            } else {
                                appStore.handoffDragScreenLocation = NSEvent.mouseLocation
                            }
                            appStore.removeAppFromFolder(dragging, folder: folder)
                            draggingApp = nil
                            dragSourceApps = nil
                            outOfBoundsBeganAt = nil
                            onClose()
                            return nil
                        }
                    } else {
                        outOfBoundsBeganAt = nil
                    }

                    refreshScrollOffset()
                    if let hoveringIndex = indexAt(point: dragPreviewPosition, containerSize: folderCurrentContainerSize, columnWidth: folderCurrentColumnWidth, appHeight: folderCurrentAppHeight) {
                        let count = visualApps.count
                        if count > 0, hoveringIndex == count - 1, dragging != visualApps[hoveringIndex] {
                            pendingDropIndex = count
                        } else {
                            pendingDropIndex = hoveringIndex
                        }
                    } else {
                        pendingDropIndex = nil
                    }
                    return nil
                }

                if let candidate = folderDragMouseDownApp {
                    let dist = hypot(localPoint.x - folderDragMouseDownLocation.x, localPoint.y - folderDragMouseDownLocation.y)
                    if dist >= 2.0 {
                        var tx = Transaction(); tx.disablesAnimations = true
                        withTransaction(tx) {
                            draggingApp = candidate
                            dragSourceApps = folder.apps
                            dragPreviewOpacity = 1.0
                            dragPreviewScale = 1.2
                            isSettlingDrop = false
                        }
                        isDraggingActive = true
                        isKeyboardNavigationActive = false
                        dragPreviewPosition = localPoint
                        folderDragMouseDownApp = nil
                    }
                }
                return event

            case .leftMouseUp:
                isDraggingActive = false
                folderDragMouseDownApp = nil
                guard !isEditingName, let dragging = draggingApp else { return event }
                isSettlingDrop = true
                defer {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        draggingApp = nil
                        dragSourceApps = nil
                        pendingDropIndex = nil
                        isSettlingDrop = false
                        dragPreviewOpacity = 1.0
                    }
                }
                if hasHandedOffDrag {
                    hasHandedOffDrag = false
                    outOfBoundsBeganAt = nil
                    return nil
                }
                if let finalIndex = pendingDropIndex {
                    let targetCenter = cellCenter(for: finalIndex, containerSize: folderCurrentContainerSize,
                                                  columnWidth: folderCurrentColumnWidth, appHeight: folderCurrentAppHeight)
                    withAnimation(LNAnimations.easeInOut) {
                        dragPreviewPosition = targetCenter
                        dragPreviewScale = 1.0
                        dragPreviewOpacity = 0.0
                    }
                    let sourceApps = dragSourceApps ?? folder.apps
                    if let from = sourceApps.firstIndex(of: dragging) {
                        var apps = sourceApps
                        apps.remove(at: from)
                        let clamped = min(max(0, finalIndex), apps.count)
                        apps.insert(dragging, at: clamped)
                        withAnimation(LNAnimations.easeInOut) {
                            appStore.reorderAppsInsideFolder(apps, in: folder)
                        }
                        lastDroppedAppID = dragging.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                            lastDroppedAppID = nil
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            appStore.compactItemsWithinPages()
                        }
                    }
                } else {
                    withAnimation(LNAnimations.easeInOut) {
                        dragPreviewScale = 1.0
                        dragPreviewOpacity = 0.0
                    }
                }
                return nil

            default:
                return event
            }
        }
    }

    private func convertScreenToFolderGrid(_ screenPoint: CGPoint) -> CGPoint {
        guard let window = NSApp.keyWindow else { return screenPoint }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let windowHeight = window.contentView?.bounds.height ?? window.frame.size.height
        let x = windowPoint.x - folderGridOriginInWindow.x
        let yFromTop = windowHeight - windowPoint.y
        let y = yFromTop - folderGridOriginInWindow.y
        return CGPoint(x: x, y: y)
    }

    private func convertWindowToFolderGrid(_ windowPoint: CGPoint) -> CGPoint {
        guard let window = NSApp.keyWindow else { return .zero }
        let windowHeight = window.contentView?.bounds.height ?? window.frame.size.height
        let yFromTop = windowHeight - windowPoint.y
        return CGPoint(x: windowPoint.x - folderGridOriginInWindow.x,
                       y: yFromTop - folderGridOriginInWindow.y)
    }

    private func refreshScrollOffset() {
        guard let clipView = folderClipView ?? findFolderClipView(in: NSApp.keyWindow?.contentView) else { return }
        if folderClipView == nil { folderClipView = clipView }
        scrollOffsetY = clipView.bounds.origin.y
    }

    private func cacheFolderClipView() {
        DispatchQueue.main.async {
            self.folderClipView = self.findFolderClipView(in: NSApp.keyWindow?.contentView)
        }
    }

    private func findFolderClipView(in view: NSView?) -> NSClipView? {
        guard let view = view else { return nil }
        if let scrollView = view as? NSScrollView {
            return scrollView.contentView
        }
        for subview in view.subviews {
            if let found = findFolderClipView(in: subview) {
                return found
            }
        }
        return nil
    }
}

extension FolderView {
    @ViewBuilder
    private func withMatchedGeometry(_ content: some View, id: String) -> some View {
        if draggingApp == nil {
            content.matchedGeometryEffect(id: id, in: reorderNamespaceFolder)
        } else {
            content
        }
    }
}

// MARK: - Drag geometry & hit-testing (folder internal)
extension FolderView {
    private func cellOrigin(for index: Int,
                            containerSize: CGSize,
                            columnWidth: CGFloat,
                            appHeight: CGFloat) -> CGPoint {
        let row = index / columnsCount
        let col = index % columnsCount
        
        // 计算在 LazyVGrid 内容坐标系中的位置
        let x = gridPadding + CGFloat(col) * (columnWidth + spacing)
        let y = gridPadding + CGFloat(row) * (appHeight + spacing)
        
        // 转换为 folderGrid 坐标系（减去滚动偏移）
        return CGPoint(x: x, y: y - scrollOffsetY)
    }

    private func cellCenter(for index: Int,
                            containerSize: CGSize,
                            columnWidth: CGFloat,
                            appHeight: CGFloat) -> CGPoint {
        let origin = cellOrigin(for: index, containerSize: containerSize, columnWidth: columnWidth, appHeight: appHeight)
        return CGPoint(x: origin.x + columnWidth / 2, y: origin.y + appHeight / 2)
    }

    private func indexAt(point: CGPoint,
                         containerSize: CGSize,
                         columnWidth: CGFloat,
                         appHeight: CGFloat) -> Int? {
        // point 是在 folderGrid 坐标系中的位置
        // 需要转换为 LazyVGrid 内容坐标
        // LazyVGrid 内容起点在 folderGrid 中的位置是 (gridPadding, gridPadding - scrollOffsetY)
        // 所以内容坐标 = point - (gridPadding, gridPadding) + scrollOffsetY
        let contentX = point.x - gridPadding
        let contentY = point.y - gridPadding + scrollOffsetY
        
        guard contentX >= 0, contentY >= 0 else { return nil }
        
        let col = Int((contentX + spacing / 2) / (columnWidth + spacing))
        let row = Int((contentY + spacing / 2) / (appHeight + spacing))
        
        guard col >= 0 && col < columnsCount && row >= 0 else { return nil }
        
        let index = row * columnsCount + col
        
        let count = visualAppSlots.count
        if count == 0 { return 0 }
        return min(max(index, 0), count)
    }
}

// MARK: - Folder scroll offset preference key
private struct FolderScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
// MARK: - Keyboard navigation (mirror outer behavior)
extension FolderView {
    private func setupKeyHandlers() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleKeyEvent(event)
        }
    }

    private func setupInitialSelection() {
        if selectedIndex == nil, folder.apps.indices.first != nil {
            selectedIndex = 0
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // 正在编辑文件夹名时，放行输入
        if isTextFieldFocused { return event }

        // Esc 关闭文件夹
        if event.keyCode == 53 {
            onClose()
            return nil
        }

        // 回车：激活或启动选择
        if event.keyCode == 36 {
            if !isKeyboardNavigationActive {
                isKeyboardNavigationActive = true
                setSelectionToStart()
                clampSelection()
                return nil
            }
            if let idx = selectedIndex, folder.apps.indices.contains(idx) {
                onLaunchApp(folder.apps[idx])
                return nil
            }
            return event
        }

        // Tab：与回车一致，先激活键盘导航
        if event.keyCode == 48 {
            if !isKeyboardNavigationActive {
                isKeyboardNavigationActive = true
                setSelectionToStart()
                clampSelection()
                return nil
            }
            return event
        }

        // 向下：先激活导航
        if event.keyCode == 125 {
            if !isKeyboardNavigationActive {
                isKeyboardNavigationActive = true
                setSelectionToStart()
                clampSelection()
                return nil
            }
            moveSelection(dx: 0, dy: 1)
            return nil
        }

        // 左右/一般箭头
        if let (dx, dy) = arrowDelta(for: event.keyCode) {
            guard isKeyboardNavigationActive else { return event }
            moveSelection(dx: dx, dy: dy)
            return nil
        }

        return event
    }

    private func moveSelection(dx: Int, dy: Int) {
        guard let current = selectedIndex else { return }
        let columnsCount = max(columnsCount, 1)
        let newIndex: Int = dy == 0 ? current + dx : current + dy * columnsCount
        guard folder.apps.indices.contains(newIndex) else { return }
        selectedIndex = newIndex
    }

    private func setSelectionToStart() {
        if let first = folder.apps.indices.first {
            selectedIndex = first
        } else {
            selectedIndex = nil
        }
    }

    private func clampSelection() {
        let count = folder.apps.count
        if count == 0 { selectedIndex = nil; return }
        if let idx = selectedIndex {
            if idx >= count { selectedIndex = count - 1 }
            if idx < 0 { selectedIndex = 0 }
        } else {
            selectedIndex = 0
        }
    }
}

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
