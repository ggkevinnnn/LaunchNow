import SwiftUI
import AppKit
import Combine

// MARK: - LaunchpadItem extension
extension LaunchpadItem {
    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

// MARK: - 简化的翻页管理器
private final class PageFlipManager: ObservableObject {
    @Published var isCooldown: Bool = false
    private var lastFlipTime: Date?
    var autoFlipInterval: TimeInterval = 0.8
    
    func canFlip() -> Bool {
        guard !isCooldown else { return false }
        guard let lastTime = lastFlipTime else { return true }
        return Date().timeIntervalSince(lastTime) >= autoFlipInterval
    }
    
    func recordFlip() {
        lastFlipTime = Date()
        isCooldown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + autoFlipInterval) {
            self.isCooldown = false
        }
    }

    func reset() {
        lastFlipTime = nil
        isCooldown = false
    }
}

private final class ScrollInteractionCoordinator: ObservableObject {
    @Published private(set) var renderedOffset: CGFloat = 0

    var accumulatedScrollX: CGFloat = 0

    private var pendingOffset: CGFloat = 0
    private var isInteractive = false
    private var hasPendingUpdate = false

    private let publishEpsilon: CGFloat = 0.1

    func beginInteractiveGesture() {
        accumulatedScrollX = 0
        isInteractive = true
        pendingOffset = 0
        hasPendingUpdate = false
        publishImmediately(0)
    }

    func updateInteractiveOffset(_ offset: CGFloat) {
        pendingOffset = offset
        coalescedPublish()
    }

    func finishInteractiveGesture() {
        accumulatedScrollX = 0
        isInteractive = false
        hasPendingUpdate = false
    }

    func publishImmediately(_ offset: CGFloat) {
        pendingOffset = offset
        if abs(renderedOffset - offset) > publishEpsilon {
            renderedOffset = offset
        } else if renderedOffset != offset {
            renderedOffset = offset
        }
    }

    private func coalescedPublish() {
        guard !hasPendingUpdate else { return }
        hasPendingUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isInteractive else { return }
            self.hasPendingUpdate = false
            if abs(self.renderedOffset - self.pendingOffset) > self.publishEpsilon {
                self.renderedOffset = self.pendingOffset
            } else if self.renderedOffset != self.pendingOffset {
                self.renderedOffset = self.pendingOffset
            }
        }
    }
}

struct LaunchpadView: View {
    @ObservedObject var appStore: AppStore
    @State private var keyMonitor: Any?
    @State private var windowObserver: NSObjectProtocol?
    @State private var focusObserver: NSObjectProtocol?
    @State private var windowHiddenObserver: NSObjectProtocol?
    @State private var draggingItem: LaunchpadItem?
    @State private var dragPreviewPosition: CGPoint = .zero
    @State private var dragPreviewScale: CGFloat = 1.2
    @State private var dragPreviewOpacity: Double = 1.0
    @State private var isSettlingDrop: Bool = false
    @State private var pendingDropIndex: Int? = nil
    @StateObject private var pageFlipManager = PageFlipManager()
    @State private var folderHoverCandidateIndex: Int? = nil
    @State private var folderHoverBeganAt: Date? = nil
    @State private var selectedIndex: Int? = nil
    @State private var isKeyboardNavigationActive: Bool = false
    @FocusState private var isSearchFieldFocused: Bool
    @Namespace private var reorderNamespace
    @State private var handoffEventMonitor: Any? = nil
    @State private var dragContinuationMonitor: Any? = nil
    @State private var globalMouseUpMonitor: Any? = nil
    @State private var gridOriginInWindow: CGPoint = .zero
    @State private var currentContainerSize: CGSize = .zero
    @State private var currentColumnWidth: CGFloat = 0
    @State private var currentAppHeight: CGFloat = 0
    @State private var currentIconSize: CGFloat = 0
    
    // Added states for drag original index and flagsChanged monitor
    @State private var dragOriginalIndex: Int? = nil
    @State private var dragSourceItems: [LaunchpadItem]? = nil
    @State private var flagsMonitor: Any? = nil
    
    // 新增：外部网格落点淡入标记
    @State private var lastDroppedItemID: String? = nil
    
    // 性能优化：使用静态缓存避免状态修改问题
    private static var geometryCache: [String: CGPoint] = [:]
    private static var lastGeometryUpdate: Date = Date.distantPast
    private let geometryCacheTimeout: TimeInterval = 0.1 // 100ms缓存超时
    
    @State private var isHandoffDragging: Bool = false
    @State private var isUserSwiping: Bool = false
    @State private var isSwipeSettling: Bool = false
    @State private var wheelAccumulatedSinceFlip: CGFloat = 0
    @State private var wheelLastDirection: Int = 0
    @State private var wheelLastFlipAt: Date? = nil
    private let wheelFlipCooldown: TimeInterval = 0.15
    // Guards async settle completion to prevent stale page commits during rapid swipes.
    @State private var activeScrollSettleToken: UUID = UUID()
    @State private var isPageTransitioning: Bool = false
    @State private var isDragEdgeFlipping: Bool = false
    @StateObject private var scrollCoordinator = ScrollInteractionCoordinator()

    // Performance: cache pages array to avoid recomputing on every interactive scroll offset update
    @State private var cachedPages: [[LaunchpadItem]] = []
    @State private var isFolderContentReady: Bool = false
    @State private var folderContentToken: UUID = UUID()

    private var isFolderOpen: Bool { appStore.openFolder != nil }
    private var isPagingInteractionActive: Bool {
        isUserSwiping || isSwipeSettling || scrollCoordinator.renderedOffset != 0 || isPageTransitioning
    }
    
    private var config: GridConfig {
        GridConfig(isFullscreen: appStore.isFullscreenMode)
    }
    
    var filteredItems: [LaunchpadItem] {
        appStore.filteredItems
    }
    
    var pages: [[LaunchpadItem]] {
        // During drag: recompute from visualItems in real time; otherwise use cache to avoid array allocation on every swipe frame
        draggingItem != nil ? makePages(from: visualItems) : (cachedPages.isEmpty ? makePages(from: filteredItems) : cachedPages)
    }

    private func rebuildPages() {
        cachedPages = makePages(from: filteredItems)
    }
    
    private var currentItems: [LaunchpadItem] {
        draggingItem != nil ? visualItems : filteredItems
    }
    
    private var visualItems: [LaunchpadItem] {
        let sourceItems = dragSourceItems ?? appStore.items
        guard let dragging = draggingItem, let pending = pendingDropIndex else { return sourceItems }
        var items = sourceItems
        if let sourceIndex = items.firstIndex(of: dragging) {
            let sourcePage = sourceIndex / config.itemsPerPage
            let targetPage = pending / config.itemsPerPage
            if sourcePage == targetPage {
                items.remove(at: sourceIndex)
            }
            // Cross-page: keep source item in place; it will be hidden
            // by the isDraggingThisTile opacity check during drag
        }
        let insertionIndex = max(0, min(pending, items.count))
        items.insert(.empty("drag_placeholder_\(dragging.id)"), at: insertionIndex)
        return items
    }
    
    private func makePages(from items: [LaunchpadItem]) -> [[LaunchpadItem]] {
        guard !items.isEmpty else { return [] }
        let itemsPerPage = config.itemsPerPage
        let totalPages = (items.count + itemsPerPage - 1) / itemsPerPage
        var result = [[LaunchpadItem]]()
        result.reserveCapacity(totalPages)
        for pageIndex in 0..<totalPages {
            let start = pageIndex * itemsPerPage
            let end = min(start + itemsPerPage, items.count)
            result.append(Array(items[start..<end]))
        }
        return result
    }
    
    var body: some View {
        GeometryReader { geo in
            let actualTopPadding = config.isFullscreen ? geo.size.height * config.topPadding : 0
            let actualBottomPadding = config.isFullscreen ? geo.size.height * config.bottomPadding : 0
            let actualHorizontalPadding = config.isFullscreen ? geo.size.width * config.horizontalPadding : 0
            
            VStack {
                // 在顶部添加动态padding（全屏模式）
                if config.isFullscreen {
                    Spacer()
                        .frame(height: actualTopPadding)
                }
                HStack(spacing: 8) {
                    TextField(NSLocalizedString("Search", comment: "Search"), text: $appStore.searchText)
                    .disabled(isFolderOpen)
                    .onChange(of: appStore.searchText) {
                        guard !isFolderOpen else { return }
                        appStore.currentPage = 0
                        selectedIndex = filteredItems.isEmpty ? nil : 0
                        isKeyboardNavigationActive = false
                        clampSelection()
                        let maxPageIndex = max(pages.count - 1, 0)
                        if appStore.currentPage > maxPageIndex {
                            appStore.currentPage = maxPageIndex
                        }
                    }
                    .focused($isSearchFieldFocused)
                    .font(.title)
                    .textFieldStyle(.plain)
                    
                    Spacer()
                    
                    Button {
                        appStore.isSetting = true
                    } label: {
                        Image(systemName: "ellipsis.circle")

                            .font(.title)
                            .foregroundStyle(.placeholder.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $appStore.isSetting) {
                        SettingsView(appStore: appStore)
                    }
                }
                .padding(.top)
                .padding(.horizontal)
                .opacity(isFolderOpen ? 0.1 : 1)
                .allowsHitTesting(!isFolderOpen)
                
                Divider()
                    .foregroundStyle(.placeholder)
                    .padding()
                    .opacity(isFolderOpen ? 0.1 : 1)
                
                GeometryReader { geo in
                    let appCountPerRow = config.columns
                    let maxRowsPerPage = Int(ceil(Double(config.itemsPerPage) / Double(appCountPerRow)))
                    let availableWidth = geo.size.width
                    let availableHeight = geo.size.height - (actualTopPadding + actualBottomPadding)
                    
                    let appHeight: CGFloat = {
                        let totalRowSpacing = config.rowSpacing * CGFloat(maxRowsPerPage - 1)
                        let height = (availableHeight - totalRowSpacing) / CGFloat(maxRowsPerPage)
                        return max(56, height)
                    }()

                    let columnWidth: CGFloat = {
                        let totalColumnSpacing = config.columnSpacing * CGFloat(appCountPerRow - 1)
                        let width = (availableWidth - totalColumnSpacing) / CGFloat(appCountPerRow)
                        return max(40, width)
                    }()

                    let iconSize: CGFloat = min(columnWidth, appHeight) * CGFloat(max(0.4, min(appStore.iconScale, 1.6)))

                    let effectivePageWidth = geo.size.width + config.pageSpacing

                    if filteredItems.isEmpty && !appStore.searchText.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "magnifyingglass")
                                .font(.largeTitle)
                                .foregroundStyle(.placeholder)
                            Text(NSLocalizedString("NoAppsFound", comment: "No apps found"))
                                .font(.title)
                                .foregroundStyle(.placeholder)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        let hStackOffset = -CGFloat(appStore.currentPage) * effectivePageWidth + scrollCoordinator.renderedOffset
                        ZStack(alignment: .topLeading) {
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard appStore.isFullscreenMode,
                                          appStore.openFolder == nil,
                                          !appStore.isFolderNameEditing else { return }
                                    AppDelegate.shared?.requestHideWindow()
                                }
                            // 内容
                            HStack(spacing: config.pageSpacing) {
                                ForEach(pages.indices, id: \.self) { index in
                                    let pageItems = pages[index]
                                    VStack(alignment: .leading, spacing: 0) {
                                        // 在网格上方添加动态padding
                                        if config.isFullscreen {
                                            Spacer()
                                                .frame(height: actualTopPadding)
                                        }
                                        if shouldRenderPage(index, totalPages: pages.count) {
                                            LazyVGrid(columns: config.gridItems, spacing: config.rowSpacing) {
                                                ForEach(Array(pageItems.enumerated()), id: \.element.id) { localOffset, item in
                                                    let globalIndex = index * config.itemsPerPage + localOffset
                                                    itemDraggable(
                                                        item: item,
                                                        globalIndex: globalIndex,
                                                        pageIndex: index,
                                                        containerSize: geo.size,
                                                        columnWidth: columnWidth,
                                                        iconSize: iconSize,
                                                        appHeight: appHeight,
                                                        labelWidth: columnWidth * 0.9,
                                                        isSelected: (!isFolderOpen && isKeyboardNavigationActive && selectedIndex == globalIndex)
                                                    )
                                                }
                                            }
                                            .frame(maxHeight: .infinity, alignment: .top)
                                            .animation(LNAnimations.easeInOut, value: pendingDropIndex)
                                        } else {
                                            Color.clear
                                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                        }
                                    }
                                    .frame(width: geo.size.width, height: geo.size.height)
                                }
                            }
                            .offset(x: hStackOffset)
                            .opacity(isFolderOpen ? 0.1 : 1)
                            .allowsHitTesting(!isFolderOpen)
                            

                            // 将预览提升到外层坐标空间，避免受到 offset 影响
                            if let draggingItem {
                                DragPreviewItem(item: draggingItem, iconSize: iconSize, labelWidth: columnWidth * 0.9, scale: dragPreviewScale)
                                    .position(x: dragPreviewPosition.x, y: dragPreviewPosition.y)
                                    .opacity(dragPreviewOpacity)
                                    .zIndex(100)
                                    .allowsHitTesting(false)
                            }
                        }
                        
                        .coordinateSpace(name: "grid")
                        .onTapGesture {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                        }
                        .onAppear {
                            rebuildPages()
                            // Pre-warm icon cache for adjacent pages so first swipe is instant
                            AppCacheManager.shared.smartPreloadIcons(
                                for: appStore.items,
                                currentPage: appStore.currentPage,
                                itemsPerPage: config.itemsPerPage
                            )
                        }
                        .onChange(of: appStore.filteredItems) { rebuildPages() }
                        .onChange(of: appStore.gridRefreshTrigger) {
                            // Soft refresh only: update cached page slices without rebuilding grid identity.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                rebuildPages()
                            }
                        }
                        .onChange(of: appStore.handoffDraggingApp) {
                            if appStore.openFolder == nil, appStore.handoffDraggingApp != nil {
                                startHandoffDragIfNeeded(geo: geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                        }
                        .onChange(of: appStore.openFolder) {
                            if let openFolder = appStore.openFolder {
                                scheduleFolderContentReveal(for: openFolder)
                            } else {
                                isFolderContentReady = false
                            }
                            if appStore.openFolder == nil, appStore.handoffDraggingApp != nil {
                                startHandoffDragIfNeeded(geo: geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                        }
                        .onChange(of: appStore.currentPage) {
                            DispatchQueue.main.async {
                                captureGridGeometry(geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                                
                                // 智能预加载当前页面和相邻页面的图标
                                if draggingItem == nil {
                                    AppCacheManager.shared.smartPreloadIcons(
                                        for: appStore.items,
                                        currentPage: appStore.currentPage,
                                        itemsPerPage: config.itemsPerPage
                                    )
                                }
                            }
                            isPageTransitioning = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                isPageTransitioning = false
                            }
                        }
                        .onChange(of: geo.size) {
                            DispatchQueue.main.async {
                                captureGridGeometry(geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                        }
                        .task {
                            await MainActor.run {
                                captureGridGeometry(geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                        }
                        // 新增：当图标缩放改变时，立刻重算 currentIconSize，推动文件夹内部图标即时刷新
                        .onChange(of: appStore.iconScale) {
                            let newSize = min(currentColumnWidth, currentAppHeight) * CGFloat(max(0.4, min(appStore.iconScale, 1.6)))
                            if newSize > 0 {
                                currentIconSize = newSize
                            }
                        }
                    }
                }
                
                // Merged PageIndicator - add tap to jump to page
                if pages.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(0..<pages.count, id: \.self) { index in
                            Circle()
                                .fill(appStore.currentPage == index ? Color.gray : Color.gray.opacity(0.3))
                                .frame(width: 8, height: 8)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    navigateToPage(index)
                                }
                        }
                    }
                    .opacity(isFolderOpen ? 0.1 : 1)
                    .allowsHitTesting(!isFolderOpen)
                }
                
                // 在页面指示圆点下方添加动态padding
                if config.isFullscreen {
                    Spacer()
                        .frame(height: actualBottomPadding)
                }

            }
            .padding(.horizontal, actualHorizontalPadding)
        }
        .padding()
        .background {
            if appStore.isGlasseffectEnabled {
                Color.clear.background(.ultraThinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: appStore.isFullscreenMode ? 0 : 30))
                Color.clear.glassEffect(.clear, in: RoundedRectangle(cornerRadius: appStore.isFullscreenMode ? 0 : 30))
            } else {
                Color.clear.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: appStore.isFullscreenMode ? 0 : 30))
            }
        }
        .ignoresSafeArea()
        .overlay(
            ZStack {
                // 全窗口滚动捕获层（不拦截点击，仅监听滚动）
                ScrollEventCatcher { deltaX, deltaY, phase, isMomentum, isPrecise in
                    let pageWidth = currentContainerSize.width + config.pageSpacing
                    handleScroll(deltaX: deltaX,
                                 deltaY: deltaY,
                                 phase: phase,
                                 isMomentum: isMomentum,
                                 isPrecise: isPrecise,
                                 pageWidth: pageWidth)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // 半透明背景：常驻，基于状态控制可点击性，避免动画退场期间拦截点击
                Color.black
                    .opacity(isFolderOpen ? 0.1 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(isFolderOpen)
                    .onTapGesture {
                        // 如果正在编辑文件夹名称，不关闭文件夹
                        if !appStore.isFolderNameEditing {
                            let closingFolder = appStore.openFolder
                            withAnimation(LNAnimations.folder) {
                                appStore.openFolder = nil
                            }
                            // 关闭后将键盘导航选中项切换到该文件夹
                            if let folder = closingFolder,
                               let idx = filteredItems.firstIndex(of: .folder(folder)) {
                                isKeyboardNavigationActive = true
                                selectedIndex = idx
                                let targetPage = idx / config.itemsPerPage
                                if targetPage != appStore.currentPage {
                                    appStore.currentPage = targetPage
                                }
                            }
                            // 关闭文件夹后恢复搜索框焦点
                            isSearchFieldFocused = true
                        }
                    }

                if let openFolder = appStore.openFolder {
                    Group {
                        GeometryReader { proxy in
                            let targetWidth = max(100, proxy.size.width * 0.7)
                            let targetHeight = max(100, proxy.size.height * 0.7)
                            let folderId = openFolder.id
                            
                            ZStack {
                                if isFolderContentReady {
                                    // 使用计算属性来确保绑定能够正确响应folderUpdateTrigger的变化
                                    let folderBinding = Binding<FolderInfo>(
                                        get: {
                                            // 每次访问都重新查找文件夹，确保获取最新状态
                                            if let idx = appStore.folders.firstIndex(where: { $0.id == folderId }) {
                                                return appStore.folders[idx]
                                            }
                                            return openFolder
                                        },
                                        set: { newValue in
                                            appStore.updateFolderSnapshot(newValue)
                                        }
                                    )
                                    
                                    FolderView(
                                        appStore: appStore,
                                        folder: folderBinding,
                                        preferredIconSize: currentIconSize,
                                        deferGridUntilOpened: false, // 图标已加载完成，立即显示网格
                                        onClose: {
                                            let closingFolder = appStore.openFolder
                                            withAnimation(LNAnimations.folder) {
                                                appStore.openFolder = nil
                                            }
                                            // 关闭后将键盘导航选中项切换到该文件夹
                                            if let folder = closingFolder,
                                               let idx = filteredItems.firstIndex(of: .folder(folder)) {
                                                isKeyboardNavigationActive = true
                                                selectedIndex = idx
                                                let targetPage = idx / config.itemsPerPage
                                                if targetPage != appStore.currentPage {
                                                    appStore.currentPage = targetPage
                                                }
                                            }
                                            // 关闭文件夹后恢复搜索框焦点
                                            isSearchFieldFocused = true
                                        },
                                        onLaunchApp: { app in
                                            launchApp(app)
                                        }
                                    )
                                    .transition(.opacity)
                                } else {
                                    FolderShellView(name: openFolder.name)
                                }
                            }
                            .environmentObject(appStore)
                            .frame(width: targetWidth, height: targetHeight)
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                            .id("folder_\(folderId)")
                            
                        }
                    }
                    .transition(.scaleWithEarlyOpacity)
                }
            }
        )
        .onChange(of: appStore.items) {
            guard draggingItem == nil else { return }
            clampSelection()
            let maxPageIndex = max(pages.count - 1, 0)
            if appStore.currentPage > maxPageIndex {
                appStore.currentPage = maxPageIndex
            }
         }
         .onChange(of: isSearchFieldFocused) { _, focused in
            if focused { isKeyboardNavigationActive = false }
         }
         .onAppear {
             setupKeyHandlers()
             setupInitialSelection()
             setupWindowShownObserver()
             setupFocusObserver()
             setupWindowHiddenObserver()
             // 监听全局鼠标抬起，确保拖拽状态被正确清理（窗口外释放时）
             if let existing = globalMouseUpMonitor { NSEvent.removeMonitor(existing) }
             globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
                 if handoffEventMonitor != nil {
                     finalizeHandoffDrag()
                 } else if draggingItem != nil {
                     finalizeDragOperation(containerSize: currentContainerSize,
                                           columnWidth: currentColumnWidth,
                                           appHeight: currentAppHeight,
                                           iconSize: currentIconSize)
                 }
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                     if draggingItem != nil {
                         draggingItem = nil
                         dragSourceItems = nil
                         pendingDropIndex = nil
                         appStore.isDragCreatingFolder = false
                         appStore.folderCreationTarget = nil
                         isSettlingDrop = false
                         resetDragPagingState()
                         if let monitor = dragContinuationMonitor { NSEvent.removeMonitor(monitor); dragContinuationMonitor = nil }
                         clampSelection()
                     }
                 }
              }
              // 监听按键修饰符变化（Option 模式）
              if let existing = flagsMonitor { NSEvent.removeMonitor(existing) }
              flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
                  let isOptionDown = event.modifierFlags.contains(.option)
                  if appStore.isOptionFolderMode != isOptionDown {
                      appStore.isOptionFolderMode = isOptionDown
                  }
                  return event
              }
              isKeyboardNavigationActive = false
              clampSelection()
              
              // 检查缓存状态
              checkCacheStatus()
          }
        .onDisappear {
            [keyMonitor, handoffEventMonitor, dragContinuationMonitor].forEach { monitor in
                if let monitor = monitor { NSEvent.removeMonitor(monitor) }
            }
            if let monitor = globalMouseUpMonitor { NSEvent.removeMonitor(monitor) }
            [windowObserver, windowHiddenObserver, focusObserver].forEach { observer in
                if let observer = observer { NotificationCenter.default.removeObserver(observer) }
            }
            if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor) }
            flagsMonitor = nil
            keyMonitor = nil
            handoffEventMonitor = nil
            dragContinuationMonitor = nil
            globalMouseUpMonitor = nil
            windowObserver = nil
            focusObserver = nil
            windowHiddenObserver = nil
        }
    }
    
    private func launchApp(_ app: AppInfo) {
        AppDelegate.shared?.requestHideWindow {
            NSWorkspace.shared.open(app.url)
        }
    }
    
    private func handleItemTap(_ item: LaunchpadItem) {
        guard draggingItem == nil else { return }
        switch item {
        case .app(let app):
            launchApp(app)
        case .folder(let folder):
            withAnimation(LNAnimations.folder) {
                appStore.openFolder = folder
            }
        case .empty:
            break
        }
    }

    private func scheduleFolderContentReveal(for folder: FolderInfo) {
        let token = UUID()
        folderContentToken = token
        isFolderContentReady = false

        let appPaths = folder.apps.map(\.url.path)
        let reveal: () -> Void = {
            guard folderContentToken == token else { return }
            withAnimation(LNAnimations.folder) {
                isFolderContentReady = true
            }
        }

        guard !appPaths.isEmpty else {
            DispatchQueue.main.async(execute: reveal)
            return
        }

        if AppCacheManager.shared.areIconsCached(for: appPaths) {
            // 图标已缓存，立即显示
            DispatchQueue.main.async(execute: reveal)
            return
        }

        // 图标未缓存，在后台线程预加载，完成后在主线程显示
        AppCacheManager.shared.preloadIcons(for: appPaths) {
            reveal()
        }
    }
    
    

    // MARK: - Handoff drag from folder
    private func startHandoffDragIfNeeded(geo: GeometryProxy, columnWidth: CGFloat, appHeight: CGFloat, iconSize: CGFloat) {
        guard draggingItem == nil, let app = appStore.handoffDraggingApp else { return }
        // 更新几何上下文
        captureGridGeometry(geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
        resetDragPagingState()

        // 初始位置：屏幕 -> 网格局部
        let screenPoint = appStore.handoffDragScreenLocation ?? NSEvent.mouseLocation
        let localPoint = convertScreenToGrid(screenPoint)

        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) {
            draggingItem = .app(app)
            dragSourceItems = appStore.items
        }
        isKeyboardNavigationActive = false
        appStore.isDragCreatingFolder = false
        appStore.folderCreationTarget = nil
        dragPreviewScale = 1.2
        dragPreviewPosition = localPoint
        // 使接力拖拽与普通拖拽一致：预创建新页面以支持边缘翻页
        isHandoffDragging = true

        // 智能跳页：根据拖拽位置决定是否跳转到合适的页面
        if let targetIndex = indexAt(point: localPoint,
                                     in: currentContainerSize,
                                     pageIndex: appStore.currentPage,
                                     columnWidth: columnWidth,
                                     appHeight: appHeight),
           currentItems.indices.contains(targetIndex) {
            let targetPage = targetIndex / config.itemsPerPage
            if targetPage != appStore.currentPage && targetPage < pages.count {
                appStore.currentPage = targetPage
            }
        }

        if let existing = handoffEventMonitor { NSEvent.removeMonitor(existing) }
        handoffEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { event in
            switch event.type {
            case .leftMouseDragged:
                let lp = convertScreenToGrid(NSEvent.mouseLocation)
                // 复用与普通拖拽相同的核心更新逻辑
                applyDragUpdate(at: lp,
                                containerSize: currentContainerSize,
                                columnWidth: currentColumnWidth,
                                appHeight: currentAppHeight,
                                iconSize: currentIconSize)
                return nil
            case .leftMouseUp:
                finalizeHandoffDrag()
                return nil
            default:
                return event
            }
        }

        appStore.handoffDraggingApp = nil
        appStore.handoffDragScreenLocation = nil
    }

    private func convertScreenToGrid(_ screenPoint: CGPoint) -> CGPoint {
        guard let window = NSApp.keyWindow else { return screenPoint }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        // SwiftUI 的 .global 顶部为原点，AppKit 窗口坐标底部为原点，需要翻转 y
        let windowHeight = window.contentView?.bounds.height ?? window.frame.size.height
        let x = windowPoint.x - gridOriginInWindow.x
        let yFromTop = windowHeight - windowPoint.y
        let y = yFromTop - gridOriginInWindow.y
        return CGPoint(x: x, y: y)
    }

    private func startDragContinuationMonitorIfNeeded() {
        guard dragContinuationMonitor == nil else { return }
        dragContinuationMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { event in
            guard draggingItem != nil, !isHandoffDragging else { return event }
            switch event.type {
            case .leftMouseDragged:
                let localPoint = convertScreenToGrid(NSEvent.mouseLocation)
                applyDragUpdate(at: localPoint,
                                containerSize: currentContainerSize,
                                columnWidth: currentColumnWidth,
                                appHeight: currentAppHeight,
                                iconSize: currentIconSize)
                return event
            case .leftMouseUp:
                finalizeDragOperation(containerSize: currentContainerSize,
                                      columnWidth: currentColumnWidth,
                                      appHeight: currentAppHeight,
                                      iconSize: currentIconSize)
                return event
            default:
                return event
            }
        }
    }

    private func stopDragContinuationMonitor() {
        if let monitor = dragContinuationMonitor {
            NSEvent.removeMonitor(monitor)
            dragContinuationMonitor = nil
        }
    }

    private func handleHandoffDragMove(to localPoint: CGPoint) {
        // 复用与普通拖拽完全一致的更新逻辑
        applyDragUpdate(at: localPoint,
                        containerSize: currentContainerSize,
                        columnWidth: currentColumnWidth,
                        appHeight: currentAppHeight,
                        iconSize: currentIconSize)
    }

    private func finalizeHandoffDrag() {
        guard !isSettlingDrop else { return }
        guard draggingItem != nil else { return }
        stopDragContinuationMonitor()
        // 在接力拖拽模式下，落点时再计算目标索引，过程中不展示吸附
        if isHandoffDragging && pendingDropIndex == nil {
            if let idx = indexAt(point: dragPreviewPosition,
                                  in: currentContainerSize,
                                  pageIndex: appStore.currentPage,
                                  columnWidth: currentColumnWidth,
                                  appHeight: currentAppHeight) {
                pendingDropIndex = idx
            } else {
                pendingDropIndex = predictedDropIndex(for: dragPreviewPosition,
                                                      in: currentContainerSize,
                                                      columnWidth: currentColumnWidth,
                                                      appHeight: currentAppHeight)
            }
        }

        withAnimation(LNAnimations.easeInOut) {
            dragPreviewOpacity = 0.0
        }
        // 让 finalizeDragOperation 处理落点排序逻辑（它内部会设置 isSettlingDrop）
        finalizeDragOperation(containerSize: currentContainerSize, columnWidth: currentColumnWidth, appHeight: currentAppHeight, iconSize: currentIconSize)

        if let monitor = handoffEventMonitor { NSEvent.removeMonitor(monitor); handoffEventMonitor = nil }
    }

    private func navigateToPage(_ targetPage: Int, animated: Bool = true) {
        let sourceItemCount: Int
        if appStore.searchText.isEmpty {
            if draggingItem != nil {
                sourceItemCount = max(dragSourceItems?.count ?? 0, appStore.items.count)
            } else {
                sourceItemCount = max(filteredItems.count, appStore.items.count)
            }
        } else {
            sourceItemCount = filteredItems.count
        }
        let maxPageIndex = max(0, (max(sourceItemCount, 1) - 1) / config.itemsPerPage)
        guard targetPage >= 0 && targetPage <= maxPageIndex else { return }
        if animated {
            withAnimation(LNAnimations.smooth) {
                appStore.currentPage = targetPage
            }
        } else {
            appStore.currentPage = targetPage
        }
        
        if isKeyboardNavigationActive, selectedIndex != nil,
           let target = desiredIndexForPageKeepingPosition(targetPage: targetPage) {
            selectedIndex = target
        }
    }

    private func navigateToNextPage() {
        navigateToPage(appStore.currentPage + 1)
    }
    
    private func navigateToPreviousPage() {
        navigateToPage(appStore.currentPage - 1)
    }

    // Use the same settle model as normal precise scroll so drag edge-flip looks identical.
    private func performSmoothPageFlipDuringDrag(to targetPage: Int, pageWidth: CGFloat) -> Bool {
        let sourcePage = appStore.currentPage
        guard targetPage != sourcePage else { return false }

        isDragEdgeFlipping = true
        let settleToken = UUID()
        activeScrollSettleToken = settleToken

        isUserSwiping = false
        isSwipeSettling = true
        scrollCoordinator.finishInteractiveGesture()
        // 一旦确认翻页，立即更新当前页；用过渡偏移保持视觉连续。
        let transitionalOffset = CGFloat(targetPage - sourcePage) * pageWidth
        var t = Transaction(animation: nil)
        t.disablesAnimations = true
        withTransaction(t) {
            appStore.currentPage = targetPage
            scrollCoordinator.publishImmediately(transitionalOffset)
        }

        withAnimation(LNAnimations.smooth, completionCriteria: .removed) {
            scrollCoordinator.publishImmediately(0)
        } completion: {
            guard activeScrollSettleToken == settleToken else {
                isSwipeSettling = false
                isDragEdgeFlipping = false
                return
            }
            guard appStore.currentPage == targetPage else {
                isSwipeSettling = false
                isDragEdgeFlipping = false
                return
            }
            isSwipeSettling = false
            isDragEdgeFlipping = false
        }
        return true
    }
    
}

// MARK: - Keyboard Navigation
extension LaunchpadView {
    private func setupWindowShownObserver() {
        if let observer = windowObserver {
            NotificationCenter.default.removeObserver(observer)
            windowObserver = nil
        }
        windowObserver = NotificationCenter.default.addObserver(forName: .launchpadWindowShown, object: nil, queue: .main) { _ in
            isKeyboardNavigationActive = false
            selectedIndex = 0
            if !appStore.apps.isEmpty {
                appStore.applyOrderAndFolders()
            }
        }
    }

    private func setupFocusObserver() {
        if let observer = focusObserver {
            NotificationCenter.default.removeObserver(observer)
            focusObserver = nil
        }
        focusObserver = NotificationCenter.default.addObserver(forName: .launchpadFocusSearchField, object: nil, queue: .main) { _ in
            self.isSearchFieldFocused = true
        }
    }

    private func setupWindowHiddenObserver() {
        if let observer = windowHiddenObserver {
            NotificationCenter.default.removeObserver(observer)
            windowHiddenObserver = nil
        }
        windowHiddenObserver = NotificationCenter.default.addObserver(forName: .launchpadWindowHidden, object: nil, queue: .main) { _ in
            selectedIndex = 0
        }
    }
    
    private func setupInitialSelection() {
        if selectedIndex == nil, let firstIndex = filteredItems.indices.first {
            selectedIndex = firstIndex
        }
    }

    private func setupKeyHandlers() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handleKeyEvent(event)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        if isFolderOpen {
            if event.keyCode == 53 { // esc
                let closingFolder = appStore.openFolder
                withAnimation(LNAnimations.folder) {
                    appStore.openFolder = nil
                }
                if let folder = closingFolder,
                   let idx = filteredItems.firstIndex(of: .folder(folder)) {
                    isKeyboardNavigationActive = true
                    selectedIndex = idx
                    let targetPage = idx / config.itemsPerPage
                    if targetPage != appStore.currentPage {
                        appStore.currentPage = targetPage
                    }
                }
                // 关闭文件夹后恢复搜索框焦点
                isSearchFieldFocused = true
                return nil
            }
            return event
        }
        
        guard !filteredItems.isEmpty else { return event }
        let code = event.keyCode

        if draggingItem != nil {
            switch code {
            case 123, 124, 125, 126, 48, 36: return nil
            default: return event
            }
        }

        if code == 53 { // esc
            AppDelegate.shared?.requestHideWindow()
            return nil
        }

        if code == 36 { // return
            if isSearchFieldFocused, isIMEComposing() { return event }
            if !isKeyboardNavigationActive {
                isKeyboardNavigationActive = true
                setSelectionToPageStart(appStore.currentPage)
                clampSelection()
                return nil
            }

            if let idx = selectedIndex, filteredItems.indices.contains(idx) {
                let sel = filteredItems[idx]
                if case .folder = sel {
                    appStore.openFolderActivatedByKeyboard = true
                }
                handleItemTap(sel)
                return nil
            }
            return event
        }

        if code == 48 { // tab
            if !isKeyboardNavigationActive {
                isKeyboardNavigationActive = true
                setSelectionToPageStart(appStore.currentPage)
                clampSelection()
                return nil
            }
            // 已激活时保留原有翻页行为（Shift 反向）
            let backward = event.modifierFlags.contains(.shift)
            if backward {
                navigateToPreviousPage()
            } else {
                navigateToNextPage()
            }
            setSelectionToPageStart(appStore.currentPage)
            return nil
        }

        // Shift + 方向键翻页
        if event.modifierFlags.contains(.shift) {
            switch code {
            case 123: // left arrow - 向前翻页
                guard isKeyboardNavigationActive else { return event }
                navigateToPreviousPage()
                setSelectionToPageStart(appStore.currentPage)
                return nil
            case 124: // right arrow - 向后翻页
                guard isKeyboardNavigationActive else { return event }
                navigateToNextPage()
                setSelectionToPageStart(appStore.currentPage)
                return nil
            default:
                break
            }
        }

        if code == 125 { // down arrow activates navigation first
            if isSearchFieldFocused, isIMEComposing() { return event }
            if !isKeyboardNavigationActive {
                isKeyboardNavigationActive = true
                setSelectionToPageStart(appStore.currentPage)
                clampSelection()
                return nil
            }
            moveSelection(dx: 0, dy: 1)
            return nil
        }

        if code == 126 { // up arrow
            guard isKeyboardNavigationActive else { return event }
            if let idx = selectedIndex {
                let columns = config.columns
                let itemsPerPage = config.itemsPerPage
                let rowInPage = (idx % itemsPerPage) / columns
                if rowInPage == 0 {
                    isKeyboardNavigationActive = false
                    selectedIndex = nil
                    return nil
                }
            }
            moveSelection(dx: 0, dy: -1)
            return nil
        }

        // 普通方向键导航（仅在非Shift状态下）
        if !event.modifierFlags.contains(.shift), let (dx, dy) = arrowDelta(for: code) {
            guard isKeyboardNavigationActive else { return event }
            moveSelection(dx: dx, dy: dy)
            return nil
        }

        return event
    }

    private func moveSelection(dx: Int, dy: Int) {
        guard let current = selectedIndex else { return }
        let columns = config.columns
        let newIndex: Int = dy == 0 ? current + dx : current + dy * columns
        guard filteredItems.indices.contains(newIndex) else { return }
        selectedIndex = newIndex
        
        let page = newIndex / config.itemsPerPage
        if page != appStore.currentPage {
            navigateToPage(page, animated: true)
        }
    }

    private func setSelectionToPageStart(_ page: Int) {
        let startIndex = page * config.itemsPerPage
        if filteredItems.indices.contains(startIndex) {
            selectedIndex = startIndex
        } else if let last = filteredItems.indices.last {
            selectedIndex = last
        } else {
            selectedIndex = nil
        }
    }

    private func desiredIndexForPageKeepingPosition(targetPage: Int) -> Int? {
        guard let current = selectedIndex else { return nil }
        let columns = config.columns
        let itemsPerPage = config.itemsPerPage
        let currentOffsetInPage = current % itemsPerPage
        let currentRow = currentOffsetInPage / columns
        let currentCol = currentOffsetInPage % columns
        let targetOffset = currentRow * columns + currentCol
        let candidate = targetPage * itemsPerPage + targetOffset

        if filteredItems.indices.contains(candidate) {
            return candidate
        }

        let startOfPage = targetPage * itemsPerPage
        let endExclusive = min((targetPage + 1) * itemsPerPage, filteredItems.count)
        let lastIndexInPage = endExclusive - 1
        return lastIndexInPage >= startOfPage ? lastIndexInPage : nil
    }
}

// MARK: - Key mapping helpers
extension LaunchpadView {
    private func isIMEComposing() -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        return editor.hasMarkedText()
    }
}

// MARK: - View builders
extension LaunchpadView {
    private func shouldRenderPage(_ index: Int, totalPages: Int) -> Bool {
        // Current page is always rendered
        if index == appStore.currentPage { return true }
        // Adjacent pages are rendered only while swiping or transitioning,
        // so they are ready the moment they slide into view.
        // isPageTransitioning stays true for 0.25s after navigation,
        // keeping them alive for rapid consecutive swipes.
        return isPagingInteractionActive && abs(index - appStore.currentPage) <= 1
    }

    @ViewBuilder
    private func withMatchedGeometry(_ content: some View, id: String) -> some View {
        if draggingItem == nil {
            content.matchedGeometryEffect(id: id, in: reorderNamespace)
        } else {
            content
        }
    }

    @ViewBuilder
    private func itemDraggable(item: LaunchpadItem,
                               globalIndex: Int,
                               pageIndex: Int,
                               containerSize: CGSize,
                               columnWidth: CGFloat,
                               iconSize: CGFloat,
                               appHeight: CGFloat,
                               labelWidth: CGFloat,
                               isSelected: Bool) -> some View {
        if case .empty = item {
            Rectangle().fill(Color.clear)
                .frame(height: appHeight)
        } else {
            let shouldAllowHover = draggingItem == nil && !isPagingInteractionActive

            let isCenterCreatingTarget: Bool = {
                guard let draggingItem, let idx = currentItems.firstIndex(of: item) else { return false }
                guard case .app = draggingItem else { return false }
                guard appStore.isDragCreatingFolder else { return false }
                switch item {
                case .app(let targetApp):
                    return appStore.folderCreationTarget?.id == targetApp.id
                case .folder:
                    return folderHoverCandidateIndex == idx
                case .empty:
                    return false
                }
            }()

            let base = LaunchpadItemButton(
                item: item,
                iconSize: iconSize,
                labelWidth: labelWidth,
                isSelected: isSelected,
                showAppNameBelowIcon: appStore.showAppNameBelowIcon,
                shouldAllowHover: shouldAllowHover,
                externalScale: isCenterCreatingTarget ? 1.2 : nil,
                onTap: { if draggingItem == nil { handleItemTap(item) } }
            )
            .equatable()
            .frame(height: appHeight)
            // 保持稳定的视图身份，避免在文件夹更新后中断拖拽手势
            .id(item.id)
            .contextMenu {
                if case .app(let app) = item, !appStore.folders.isEmpty {
                    Menu(NSLocalizedString("MoveToFolder", comment: "Move to folder")) {
                        ForEach(appStore.folders) { folder in
                            Button(action: {
                                appStore.addAppToFolder(app, folder: folder)
                            }) {
                                Label(folder.name, systemImage: "folder")
                            }
                        }
                    }
                }
            }

            // Use @ViewBuilder conditional instead of AnyView to allow SwiftUI structural diffing
            if appStore.searchText.isEmpty && !isFolderOpen {
                let isDraggingThisTile = (draggingItem == item)

                withMatchedGeometry(base, id: item.id)
                    // Fade in newly dropped item
                    .opacity((lastDroppedItemID == item.id) ? 0 : 1)
                    .animation(LNAnimations.easeInOut, value: lastDroppedItemID)
                    // Hide tile while it is being dragged
                    .opacity((isDraggingThisTile && !isSettlingDrop) ? 0 : 1)
                    .animation(LNAnimations.easeInOut, value: isSettlingDrop)
                    .allowsHitTesting(!isDraggingThisTile)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .named("grid"))
                            .onChanged { value in
                                handleDragChange(value, item: item, in: containerSize, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                            .onEnded { _ in
                                guard draggingItem != nil else { return }

                                // Finalize drag operation
                                finalizeDragOperation(containerSize: containerSize, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                    )
            } else {
                withMatchedGeometry(base, id: item.id)
                    // Fade in newly dropped item
                    .opacity((lastDroppedItemID == item.id) ? 0 : 1)
                    .animation(LNAnimations.easeInOut, value: lastDroppedItemID)
            }
        }
    }
}


// MARK: - Drag math helpers
extension LaunchpadView {
    private func pageOf(index: Int) -> Int { index / config.itemsPerPage }

    private func cellOrigin(for globalIndex: Int,
                            in containerSize: CGSize,
                            pageIndex: Int,
                            columnWidth: CGFloat,
                            appHeight: CGFloat) -> CGPoint {
        let columns = config.columns
        let displayedOffsetInPage: Int = {
            guard pages.indices.contains(pageIndex), currentItems.indices.contains(globalIndex) else {
                return globalIndex % config.itemsPerPage
            }
            let pageItems = pages[pageIndex]
            let item = currentItems[globalIndex]
            return pageItems.firstIndex(of: item) ?? (globalIndex % config.itemsPerPage)
        }()
        
        let verticalOffset = config.isFullscreen ? (currentContainerSize.height * config.topPadding) : 0
        let base = GeometryUtils.cellOrigin(for: displayedOffsetInPage,
                                      containerSize: containerSize,
                                      pageIndex: pageIndex,
                                      columnWidth: columnWidth,
                                      appHeight: appHeight,
                                      columns: columns,
                                      columnSpacing: config.columnSpacing,
                                      rowSpacing: config.rowSpacing,
                                      pageSpacing: config.pageSpacing,
                                      currentPage: appStore.currentPage)
        return CGPoint(x: base.x, y: base.y + verticalOffset)
    }

    private func cellCenter(for globalIndex: Int,
                            in containerSize: CGSize,
                            pageIndex: Int,
                            columnWidth: CGFloat,
                            appHeight: CGFloat) -> CGPoint {
        // 性能优化：使用缓存避免重复计算
        let cacheKey = "center_\(globalIndex)_\(pageIndex)_\(containerSize.width)_\(containerSize.height)_\(columnWidth)_\(appHeight)"
        
        // 检查缓存是否有效
        let now = Date()
        if now.timeIntervalSince(Self.lastGeometryUpdate) < geometryCacheTimeout,
           let cached = Self.geometryCache[cacheKey] {
            return cached
        }
        
        let origin = cellOrigin(for: globalIndex, in: containerSize, pageIndex: pageIndex, columnWidth: columnWidth, appHeight: appHeight)
        let center = CGPoint(x: origin.x + columnWidth / 2, y: origin.y + appHeight / 2)
        
        // 直接更新缓存（这些函数总是在主线程调用）
        Self.geometryCache[cacheKey] = center
        Self.lastGeometryUpdate = now
        
        return center
    }

    private func indexAt(point: CGPoint,
                         in containerSize: CGSize,
                         pageIndex: Int,
                         columnWidth: CGFloat,
                         appHeight: CGFloat) -> Int? {
        guard pages.indices.contains(pageIndex) else { return nil }
        let pageItems = pages[pageIndex]
        
        let verticalOffset = config.isFullscreen ? (currentContainerSize.height * config.topPadding) : 0
        let adjustedPoint = CGPoint(x: point.x, y: point.y - verticalOffset)
        
        guard let offsetInPage = GeometryUtils.indexAt(point: adjustedPoint,
                                                      containerSize: containerSize,
                                                      pageIndex: pageIndex,
                                                      columnWidth: columnWidth,
                                                      appHeight: appHeight,
                                                      columns: config.columns,
                                                      columnSpacing: config.columnSpacing,
                                                      rowSpacing: config.rowSpacing,
                                                      pageSpacing: config.pageSpacing,
                                                      currentPage: appStore.currentPage,
                                                      itemsPerPage: config.itemsPerPage,
                                                      pageItems: pageItems) else { return nil }
        
        let startIndexInCurrentItems = pages.prefix(pageIndex).reduce(0) { $0 + $1.count }
        let globalIndex = startIndexInCurrentItems + offsetInPage
        return currentItems.indices.contains(globalIndex) ? globalIndex : nil
    }

    private func isPointInCenterArea(point: CGPoint,
                                      targetIndex: Int,
                                      containerSize: CGSize,
                                      pageIndex: Int,
                                      columnWidth: CGFloat,
                                      appHeight: CGFloat,
                                      iconSize: CGFloat) -> Bool {
        // 性能优化：使用缓存避免重复计算
        let cacheKey = "centerArea_\(targetIndex)_\(pageIndex)_\(containerSize.width)_\(containerSize.height)_\(columnWidth)_\(appHeight)_\(iconSize)"
        
        let now = Date()
        if now.timeIntervalSince(Self.lastGeometryUpdate) < geometryCacheTimeout,
           let cached = Self.geometryCache[cacheKey] {
            let centerAreaSize = iconSize * 1.6
            let centerAreaRect = CGRect(
                x: cached.x - centerAreaSize / 2,
                y: cached.y - centerAreaSize / 2,
                width: centerAreaSize,
                height: centerAreaSize
            )
            return centerAreaRect.contains(point)
        }
        
        let targetCenter = cellCenter(for: targetIndex, in: containerSize, pageIndex: pageIndex, columnWidth: columnWidth, appHeight: appHeight)
        let scale: CGFloat = 1.2
        let centerAreaSize = iconSize * scale
        let centerAreaRect = CGRect(
            x: targetCenter.x - centerAreaSize / 2,
            y: targetCenter.y - centerAreaSize / 2,
            width: centerAreaSize,
            height: centerAreaSize
        )
        
        // 直接更新缓存（这些函数总是在主线程调用）
        Self.geometryCache[cacheKey] = targetCenter
        Self.lastGeometryUpdate = now
        
        return centerAreaRect.contains(point)
    }
}

// MARK: - Scroll handling (mouse wheel and trackpad)
extension LaunchpadView {
    private func handleScroll(deltaX: CGFloat,
                              deltaY: CGFloat,
                              phase: NSEvent.Phase,
                              isMomentum: Bool,
                              isPrecise: Bool,
                              pageWidth: CGFloat) {
        guard !isFolderOpen, !appStore.isSetting else { return }
        // Mouse wheel (non-precise): accumulate distance; apply small cooldown to avoid multi-page flips
        if !isPrecise {
            // Map vertical wheel to horizontal direction like precise scroll
            let primaryDelta = abs(deltaX) >= abs(deltaY) ? deltaX : -deltaY
            if primaryDelta == 0 { return }
            let direction = primaryDelta > 0 ? 1 : -1
            if wheelLastDirection != direction { wheelAccumulatedSinceFlip = 0 }
            wheelLastDirection = direction
            wheelAccumulatedSinceFlip += abs(primaryDelta)
            let threshold: CGFloat = 2.0 / CGFloat(appStore.scrollSensitivity / 0.15) // 根据灵敏度调整鼠标滚轮阈值
            let now = Date()
            if wheelAccumulatedSinceFlip >= threshold {
                if let last = wheelLastFlipAt, now.timeIntervalSince(last) < wheelFlipCooldown { return }
                if direction > 0 { navigateToNextPage() } else { navigateToPreviousPage() }
                wheelLastFlipAt = now
                // reset accumulation so one wheel tick only flips once
                wheelAccumulatedSinceFlip = 0
            }
            return
        }

        // Trackpad precise scroll: interactive follow + settle
        if isMomentum { return }
        let delta = abs(deltaX) >= abs(deltaY) ? deltaX : -deltaY // vertical swipes map to horizontal
        switch phase {
        case .began:
            // Invalidate any previous settle completion.
            let settleToken = UUID()
            activeScrollSettleToken = settleToken
            // If a previous swipe's settle-animation is still in flight, snap currentPage to the
            // nearest page before resetting io=0, so the visual doesn't jump to the wrong page.
            let currentOffset = scrollCoordinator.renderedOffset
            if currentOffset != 0 {
                if currentOffset <= -pageWidth / 2 {
                    appStore.currentPage = min(appStore.currentPage + 1, pages.count - 1)
                } else if currentOffset >= pageWidth / 2 {
                    appStore.currentPage = max(appStore.currentPage - 1, 0)
                }
            }
            isUserSwiping = true
            isSwipeSettling = false
            scrollCoordinator.beginInteractiveGesture()
        case .changed:
            if !isUserSwiping {
                isUserSwiping = true
            }
            scrollCoordinator.accumulatedScrollX += delta
            // 将累计滚动直接映射为页面容器偏移（与原版Launchpad类似）
            var proposed = scrollCoordinator.accumulatedScrollX
            let atFirstPage = appStore.currentPage <= 0
            let atLastPage = appStore.currentPage >= max(pages.count - 1, 0)
            // 橡皮筋函数：limit为单页宽度
            func rubberband(_ x: CGFloat, limit: CGFloat) -> CGFloat {
                let a: CGFloat = 0.55 // 弹性系数
                let d = abs(x)
                let result = (a * d) / (d + limit)
                return result * (x >= 0 ? 1 : -1) * limit
            }
            if atFirstPage && proposed > 0 {
                proposed = rubberband(proposed, limit: pageWidth)
            } else if atLastPage && proposed < 0 {
                proposed = rubberband(proposed, limit: pageWidth)
            } else {
                // 中间页：限制在一页范围内，避免跨越两页
                proposed = max(-pageWidth, min(pageWidth, proposed))
            }
            scrollCoordinator.updateInteractiveOffset(proposed)
        case .ended, .cancelled:
            // Larger sensitivity → smaller threshold (consistent with original logic)
            let settleToken = activeScrollSettleToken
            let threshold = pageWidth * (0.0225 / max(appStore.scrollSensitivity, 0.001))
            let targetPage: Int
            if scrollCoordinator.accumulatedScrollX <= -threshold {
                targetPage = min(appStore.currentPage + 1, pages.count - 1)
            } else if scrollCoordinator.accumulatedScrollX >= threshold {
                targetPage = max(appStore.currentPage - 1, 0)
            } else {
                targetPage = appStore.currentPage
            }

            // We commit the page change immediately when the flip decision is made.
            // Preserve visual continuity: after committing the page, set IO so that
            // hStackOffset remains the same at the commit frame.
            // Before: h = -(oldPage * W) + IO
            // After:  h = -(newPage * W) + IO' = h  ⇒  IO' = IO + (newPage - oldPage) * W
            let oldPage = appStore.currentPage
            let previousIO = scrollCoordinator.renderedOffset
            let transitionalOffset = previousIO + CGFloat(targetPage - oldPage) * pageWidth

            // Reset swipe state and commit page instantly (no animation),
            // then animate the offset back to 0 to complete the visual transition.
            isUserSwiping = false
            isSwipeSettling = true
            scrollCoordinator.finishInteractiveGesture()

            var t = Transaction(animation: nil)
            t.disablesAnimations = true
            withTransaction(t) {
                appStore.currentPage = targetPage
                scrollCoordinator.publishImmediately(transitionalOffset)
            }

            withAnimation(LNAnimations.smooth, completionCriteria: .removed) {
                scrollCoordinator.publishImmediately(0)
            } completion: {
                guard activeScrollSettleToken == settleToken else { return }
                isSwipeSettling = false
            }
        default:
            break
        }
    }
}

// MARK: - AppKit Scroll catcher
struct ScrollEventCatcher: NSViewRepresentable {
    typealias NSViewType = ScrollEventCatcherView
    let onScroll: (CGFloat, CGFloat, NSEvent.Phase, Bool, Bool) -> Void

    func makeNSView(context: Context) -> ScrollEventCatcherView {
        let view = ScrollEventCatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollEventCatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollEventCatcherView: NSView {
        var onScroll: ((CGFloat, CGFloat, NSEvent.Phase, Bool, Bool) -> Void)?
        private var eventMonitor: Any?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor = eventMonitor { NSEvent.removeMonitor(monitor); eventMonitor = nil }
            // Only forward scroll events for this window to keep the hot path narrow.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self, event.window === self.window else {
                    return event
                }
                guard self.onScroll != nil else { return event }
                let deltaX = event.scrollingDeltaX
                let deltaY = event.scrollingDeltaY
                guard deltaX != 0 || deltaY != 0 || event.phase != [] || event.momentumPhase != [] else {
                    return event
                }
                let phase = event.phase != [] ? event.phase : event.momentumPhase
                let isMomentum = event.momentumPhase != []
                let isPreciseOrTrackpad = event.hasPreciseScrollingDeltas || event.phase != [] || event.momentumPhase != []
                self.onScroll?(deltaX,
                               deltaY,
                               phase,
                               isMomentum,
                               isPreciseOrTrackpad)
                return event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // 不拦截命中测试，让下层视图处理点击/拖拽等
            return nil
        }

        deinit {
            if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

// MARK: - Drag preview view



// MARK: - Selection Helpers
extension LaunchpadView {
    private func clampSelection() {
        guard isKeyboardNavigationActive else { return }
        let count = filteredItems.count
        if count == 0 {
            selectedIndex = nil
            return
        }
        if let idx = selectedIndex {
            if idx >= count { selectedIndex = count - 1 }
            if idx < 0 { selectedIndex = 0 }
        } else {
            selectedIndex = 0
        }
        
        if let idx = selectedIndex, filteredItems.indices.contains(idx) {
            let page = idx / config.itemsPerPage
            if page != appStore.currentPage {
                navigateToPage(page, animated: true)
            }
        } else {
            selectedIndex = filteredItems.isEmpty ? nil : 0
        }
    }
}

// MARK: - Geometry & Drag helpers
extension LaunchpadView {
    fileprivate func captureGridGeometry(_ geo: GeometryProxy, columnWidth: CGFloat, appHeight: CGFloat, iconSize: CGFloat) {
        gridOriginInWindow = geo.frame(in: .global).origin
        currentContainerSize = geo.size
        currentColumnWidth = columnWidth
        currentAppHeight = appHeight
        currentIconSize = iconSize
        
        // 性能优化：清理过期的几何缓存
        let now = Date()
        if now.timeIntervalSince(Self.lastGeometryUpdate) > geometryCacheTimeout * 2 {
            // 异步清理缓存，避免在视图更新期间修改状态
            DispatchQueue.main.async {
                Self.geometryCache.removeAll()
                Self.lastGeometryUpdate = now
            }
        }
    }

    fileprivate func flipPageIfNeeded(at point: CGPoint, in containerSize: CGSize) -> Bool {
        let edgeMargin: CGFloat = config.pageNavigation.edgeFlipMargin
        let pageWidth = containerSize.width + config.pageSpacing
        
        // 检查翻页冷却状态
        pageFlipManager.autoFlipInterval = config.pageNavigation.autoFlipInterval
        guard pageFlipManager.canFlip() else { return false }
                
        if point.x <= edgeMargin && appStore.currentPage > 0 {
            let targetPage = appStore.currentPage - 1
            if performSmoothPageFlipDuringDrag(to: targetPage, pageWidth: pageWidth) {
                pageFlipManager.recordFlip()
                return true
            }
            return false
        } else if point.x >= containerSize.width - edgeMargin {
            let nextPage = appStore.currentPage + 1
            let itemsPerPage = config.itemsPerPage
            let storePageCount = max(1, (appStore.items.count + itemsPerPage - 1) / itemsPerPage)

            // 右边缘超出最后一页时，最多只新增一页（AppStore 内部负责去重）
            if nextPage >= storePageCount {
                _ = appStore.createNewPageForDrag()
            }

            let maxPageIndex = max(0, (max(appStore.items.count, 1) - 1) / itemsPerPage)
            let targetPage = min(nextPage, maxPageIndex)
            if performSmoothPageFlipDuringDrag(to: targetPage, pageWidth: pageWidth) {
                pageFlipManager.recordFlip()
                return true
            }
            return false
        }
        
        return false
    }

    fileprivate func predictedDropIndex(for point: CGPoint, in containerSize: CGSize, columnWidth: CGFloat, appHeight: CGFloat) -> Int? {
        if let predicted = indexAt(point: point,
                                   in: containerSize,
                                   pageIndex: appStore.currentPage,
                                   columnWidth: columnWidth,
                                   appHeight: appHeight) {
            return predicted
        }
        
        let edgeMargin: CGFloat = config.pageNavigation.edgeFlipMargin
        let itemsPerPage = config.itemsPerPage
        let effectiveCount = max(currentItems.count, appStore.items.count)
        
        if point.x <= edgeMargin && appStore.currentPage > 0 {
            let prevPage = appStore.currentPage - 1
            let prevPageStart = prevPage * itemsPerPage
            let prevPageEnd = min(prevPageStart + itemsPerPage, effectiveCount)
            return max(prevPageStart, prevPageEnd - 1)
        } else if point.x >= containerSize.width - edgeMargin {
            let nextPage = appStore.currentPage + 1
            let nextPageStart = nextPage * itemsPerPage
            
            // 如果拖拽到新页面，确保能够正确预测到新页面的第一个位置
            if nextPageStart >= effectiveCount {
                // 拖拽到全新页面，返回新页面的第一个位置
                return nextPageStart
            } else {
                return min(nextPageStart, effectiveCount - 1)
            }
        } else {
            if point.x <= edgeMargin {
                return appStore.currentPage * itemsPerPage
            } else {
                let currentPageEnd = min((appStore.currentPage + 1) * itemsPerPage, effectiveCount)
                return max(appStore.currentPage * itemsPerPage, currentPageEnd - 1)
            }
        }
    }
}

// MARK: - 缓存管理扩展

extension LaunchpadView {
    /// 检查缓存状态
    private func checkCacheStatus() {
        // 如果缓存无效，触发重新扫描
        if !AppCacheManager.shared.isCacheValid {
    
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.appStore.performInitialScanIfNeeded()
            }
        }
    }
    
    // MARK: - 简化的拖拽处理函数
    private func handleDragChange(_ value: DragGesture.Value, item: LaunchpadItem, in containerSize: CGSize, columnWidth: CGFloat, appHeight: CGFloat, iconSize: CGFloat) {
        // 初始化拖拽
        if draggingItem == nil {
            resetDragPagingState()
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) {
                draggingItem = item
                dragSourceItems = appStore.items
            }
            dragOriginalIndex = appStore.items.firstIndex(of: item) ?? filteredItems.firstIndex(of: item)
            isKeyboardNavigationActive = false
            appStore.isDragCreatingFolder = false
            appStore.folderCreationTarget = nil
            dragPreviewPosition = value.location
            startDragContinuationMonitorIfNeeded()
        }
        applyDragUpdate(at: value.location,
                        containerSize: containerSize,
                        columnWidth: columnWidth,
                        appHeight: appHeight,
                        iconSize: iconSize)
    }

    // 统一的拖拽结束处理逻辑（普通拖拽与接力拖拽共用）
    private func finalizeDragOperation(containerSize: CGSize, columnWidth: CGFloat, appHeight: CGFloat, iconSize: CGFloat) {
        guard !isSettlingDrop else { return }
        guard let dragging = draggingItem else { return }
        stopDragContinuationMonitor()
        isSettlingDrop = true
        
        // Option 模式：如果没有成功创建/加入文件夹，则撤销放置并回弹
        if appStore.isOptionFolderMode {
            if appStore.isDragCreatingFolder {
                // 将在后续文件夹逻辑中处理
            } else {
                // 回弹到原始位置
                if let original = dragOriginalIndex {
                    let targetCenter = cellCenter(for: original,
                                                  in: containerSize,
                                                  pageIndex: pageOf(index: original),
                                                  columnWidth: columnWidth,
                                                  appHeight: appHeight)
                    withAnimation(LNAnimations.easeInOut) {
                        dragPreviewPosition = targetCenter
                        dragPreviewScale = 1.0
                        dragPreviewOpacity = 0.0
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    draggingItem = nil
                    dragSourceItems = nil
                    pendingDropIndex = nil
                    dragOriginalIndex = nil
                    resetDragPagingState()
                    appStore.isDragCreatingFolder = false
                    appStore.folderCreationTarget = nil
                    clearHoveringState()
                    isSettlingDrop = false
                    dragPreviewOpacity = 1.0
                    clampSelection()
                }
                return
            }
        }
        
        // 处理文件夹创建逻辑
        if appStore.isDragCreatingFolder, case .app(let app) = dragging {
            if let targetApp = appStore.folderCreationTarget {
                if let insertAt = appStore.items.firstIndex(where: {
                    if case .app(let candidate) = $0 {
                        return candidate.id == targetApp.id
                    }
                    return false
                }) {
                    let newFolder = appStore.createFolder(with: [app, targetApp], insertAt: insertAt)
                    if let folderIndex = appStore.items.firstIndex(where: {
                        if case .folder(let folder) = $0 {
                            return folder.id == newFolder.id
                        }
                        return false
                    }) {
                        let targetCenter = cellCenter(for: folderIndex,
                                                      in: containerSize,
                                                      pageIndex: pageOf(index: folderIndex),
                                                      columnWidth: columnWidth,
                                                      appHeight: appHeight)
                        withAnimation(LNAnimations.easeInOut) {
                            dragPreviewPosition = targetCenter
                            dragPreviewScale = 1.0
                            dragPreviewOpacity = 0.0
                        }
                    }
                } else {
                    let newFolder = appStore.createFolder(with: [app, targetApp])
                    if let folderIndex = appStore.items.firstIndex(where: {
                        if case .folder(let folder) = $0 {
                            return folder.id == newFolder.id
                        }
                        return false
                    }) {
                        let targetCenter = cellCenter(for: folderIndex,
                                                      in: containerSize,
                                                      pageIndex: pageOf(index: folderIndex),
                                                      columnWidth: columnWidth,
                                                      appHeight: appHeight)
                        withAnimation(LNAnimations.easeInOut) {
                            dragPreviewPosition = targetCenter
                            dragPreviewScale = 1.0
                            dragPreviewOpacity = 0.0
                        }
                    }
                }
                // 文件夹创建完成后不需要额外淡入
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    draggingItem = nil
                    dragSourceItems = nil
                    pendingDropIndex = nil
                    dragOriginalIndex = nil
                    resetDragPagingState()
                    clearHoveringState()
                    isSettlingDrop = false
                    dragPreviewOpacity = 1.0
                    clampSelection()
                }
                return
            } else {
                if let hoveringIndex = indexAt(point: dragPreviewPosition,
                                               in: containerSize,
                                               pageIndex: appStore.currentPage,
                                               columnWidth: columnWidth,
                                               appHeight: appHeight),
                   currentItems.indices.contains(hoveringIndex),
                   case .folder(let folder) = currentItems[hoveringIndex] {
                    appStore.addAppToFolder(app, folder: folder)
                    let targetCenter = cellCenter(for: hoveringIndex,
                                                  in: containerSize,
                                                  pageIndex: appStore.currentPage,
                                                  columnWidth: columnWidth,
                                                  appHeight: appHeight)
                    withAnimation(LNAnimations.easeInOut) {
                        dragPreviewPosition = targetCenter
                        dragPreviewScale = 1.0
                        dragPreviewOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        draggingItem = nil
                        dragSourceItems = nil
                        pendingDropIndex = nil
                        dragOriginalIndex = nil
                        resetDragPagingState()
                        clearHoveringState()
                        isSettlingDrop = false
                        dragPreviewOpacity = 1.0
                        clampSelection()
                    }
                    return
                }
            }
            appStore.isDragCreatingFolder = false
            appStore.folderCreationTarget = nil
        }
        
        // 处理普通拖拽逻辑
        let sourceItems = dragSourceItems ?? appStore.items
        if let sourceIndexInItems = sourceItems.firstIndex(of: dragging) {
            let itemsPerPage = config.itemsPerPage
            let currentPageStart = appStore.currentPage * itemsPerPage
            let currentPageEndExclusive = min(currentPageStart + itemsPerPage, sourceItems.count)
            let currentPageLastIndex = max(currentPageStart, currentPageEndExclusive - 1)

            // Use pendingDropIndex if already set during drag, otherwise compute from pointer position
            let resolvedCurrentPageIndex: Int = {
                if let pending = pendingDropIndex, pending >= 0, pending < sourceItems.count {
                    return pending
                }
                if let idx = indexAt(point: dragPreviewPosition,
                                     in: containerSize,
                                     pageIndex: appStore.currentPage,
                                     columnWidth: columnWidth,
                                     appHeight: appHeight),
                   idx >= currentPageStart,
                   idx < currentPageEndExclusive {
                    return idx
                }
                return currentPageLastIndex
            }()
            let boundedFinalIndex = max(0, min(resolvedCurrentPageIndex, max(sourceItems.count - 1, 0)))
            pendingDropIndex = boundedFinalIndex
            // 检查是否为跨页拖拽
            let targetPage = boundedFinalIndex / config.itemsPerPage
            let sourcePage = sourceIndexInItems / config.itemsPerPage
            
            // 视觉吸附到目标格中心
            let dropDisplayIndex = boundedFinalIndex
            let finalPage = pageOf(index: dropDisplayIndex)
            let targetCenter = cellCenter(for: dropDisplayIndex,
                                          in: containerSize,
                                          pageIndex: finalPage,
                                          columnWidth: columnWidth,
                                          appHeight: appHeight)
            withAnimation(LNAnimations.easeInOut) {
                dragPreviewPosition = targetCenter
                dragPreviewScale = 1.0
                dragPreviewOpacity = 0.0
            }
            
            // 设置“落点淡入”的标记
            lastDroppedItemID = dragging.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                lastDroppedItemID = nil
            }
            
            if targetPage == sourcePage {
                // 同页内移动：使用原有的页内排序逻辑
                let pageStart = (boundedFinalIndex / config.itemsPerPage) * config.itemsPerPage
                let pageEnd = min(pageStart + config.itemsPerPage, sourceItems.count)
                var newItems = sourceItems
                var pageSlice = Array(newItems[pageStart..<pageEnd])
                let localFrom = sourceIndexInItems - pageStart
                let localTo = max(0, min(boundedFinalIndex - pageStart, pageSlice.count - 1))
                let moving = pageSlice.remove(at: localFrom)
                pageSlice.insert(moving, at: localTo)
                newItems.replaceSubrange(pageStart..<pageEnd, with: pageSlice)
                withAnimation(LNAnimations.easeInOut) {
                    appStore.items = newItems
                }
                appStore.triggerGridRefresh()
                appStore.refreshFilteredItemsForImmediateUIConsistency()
                appStore.saveAllOrder()
            } else {
                // 跨页拖拽：使用级联插入逻辑
                appStore.moveItemAcrossPagesWithCascade(item: dragging, to: boundedFinalIndex, using: sourceItems)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                draggingItem = nil
                dragSourceItems = nil
                pendingDropIndex = nil
                dragOriginalIndex = nil
                resetDragPagingState()
                clearHoveringState()
                isSettlingDrop = false
                dragPreviewOpacity = 1.0
                clampSelection()
                appStore.cleanupUnusedNewPage()
                appStore.removeEmptyPages()
                appStore.pruneEmptyFolders()
                appStore.saveAllOrder()
                if targetPage == sourcePage {
                    appStore.compactItemsWithinPages()
                }
            }
            
        } else {
            // 若过滤结果瞬时变化导致找不到拖拽项，仍做收尾，避免卡死状态
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                draggingItem = nil
                dragSourceItems = nil
                pendingDropIndex = nil
                dragOriginalIndex = nil
                resetDragPagingState()
                clearHoveringState()
                isSettlingDrop = false
                dragPreviewOpacity = 1.0
                clampSelection()
                appStore.cleanupUnusedNewPage()
                appStore.removeEmptyPages()
                appStore.pruneEmptyFolders()
                appStore.saveAllOrder()
            }
        }
    }

    private func resetDragPagingState() {
        pageFlipManager.reset()
        activeScrollSettleToken = UUID()
        isHandoffDragging = false
        isDragEdgeFlipping = false
        isUserSwiping = false
        isSwipeSettling = false
        scrollCoordinator.finishInteractiveGesture()
        scrollCoordinator.publishImmediately(0)
    }

    // 统一的拖拽更新逻辑（普通拖拽与接力拖拽共用）
    private func applyDragUpdate(at point: CGPoint,
                                 containerSize: CGSize,
                                 columnWidth: CGFloat,
                                 appHeight: CGFloat,
                                 iconSize: CGFloat) {
        // 性能优化：减少频繁的位置更新
        let distance = sqrt(pow(dragPreviewPosition.x - point.x, 2) + pow(dragPreviewPosition.y - point.y, 2))
        let edgeMargin: CGFloat = config.pageNavigation.edgeFlipMargin
        let isNearEdge = point.x <= edgeMargin || point.x >= containerSize.width - edgeMargin
        if distance < 2.0 && !isNearEdge { return } // 边缘翻页时允许小位移持续更新
        
        dragPreviewPosition = point
        
        // 性能优化：使用节流机制减少计算频率
        let now = Date()
        if now.timeIntervalSince(Self.lastGeometryUpdate) < 0.016 { // 约60fps
            return
        }
        
        // 异步更新几何缓存时间戳，避免在视图更新期间修改状态
        DispatchQueue.main.async {
            Self.lastGeometryUpdate = now
        }
        
        if let hoveringIndex = indexAt(point: dragPreviewPosition,
                                       in: containerSize,
                                       pageIndex: appStore.currentPage,
                                       columnWidth: columnWidth,
                                       appHeight: appHeight),
           currentItems.indices.contains(hoveringIndex) {
            if appStore.isOptionFolderMode {
                // 仅允许在中心区域触发文件夹创建/加入；不设置 pendingDropIndex 以禁止让位
                let isCenter = isPointInCenterArea(point: dragPreviewPosition,
                                                   targetIndex: hoveringIndex,
                                                   containerSize: currentContainerSize,
                                                   pageIndex: appStore.currentPage,
                                                   columnWidth: currentColumnWidth,
                                                   appHeight: currentAppHeight,
                                                   iconSize: currentIconSize)
                if isCenter {
                    // 复用 hover 逻辑，但强制其不产生 pendingDropIndex
                    handleHoveringLogic(hoveringIndex: hoveringIndex, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                    pendingDropIndex = nil
                } else {
                    clearHoveringState()
                }
            } else {
                handleHoveringLogic(hoveringIndex: hoveringIndex, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
            }
        } else {
            clearHoveringState()
        }

        if flipPageIfNeeded(at: point, in: containerSize) {
            if appStore.isOptionFolderMode {
                pendingDropIndex = nil
            } else {
                pendingDropIndex = predictedDropIndex(for: point, in: containerSize, columnWidth: columnWidth, appHeight: appHeight)
            }
        }
    }
    
    private func handleHoveringLogic(hoveringIndex: Int, columnWidth: CGFloat, appHeight: CGFloat, iconSize: CGFloat) {
        let hoveringItem = currentItems[hoveringIndex]
        guard pageOf(index: hoveringIndex) == appStore.currentPage else {
            clearHoveringState()
            return
        }

        let isInCenterArea = isPointInCenterArea(
            point: dragPreviewPosition,
            targetIndex: hoveringIndex,
            containerSize: currentContainerSize,
            pageIndex: appStore.currentPage,
            columnWidth: currentColumnWidth,
            appHeight: currentAppHeight,
            iconSize: currentIconSize
        )

        guard let dragging = draggingItem else { return }

        switch hoveringItem {
        case .app(let targetApp):
            handleAppHover(dragging: dragging, targetApp: targetApp, hoveringIndex: hoveringIndex, isInCenterArea: isInCenterArea)
        case .folder(_):
            handleFolderHover(dragging: dragging, hoveringIndex: hoveringIndex, isInCenterArea: isInCenterArea)
        case .empty:
            appStore.isDragCreatingFolder = false
            appStore.folderCreationTarget = nil
            pendingDropIndex = hoveringIndex
        }
    }
    
    private func handleAppHover(dragging: LaunchpadItem, targetApp: AppInfo, hoveringIndex: Int, isInCenterArea: Bool) {
        if dragging == .app(targetApp) {
            // Hovering over ourselves due to reorder shifting the dragged item into this slot.
            // Look up the ORIGINAL item at this grid position so folder creation still works.
            let sourceItems = dragSourceItems ?? appStore.items
            if sourceItems.indices.contains(hoveringIndex),
               case .app(let originalApp) = sourceItems[hoveringIndex],
               originalApp.id != targetApp.id {
                handleAppToAppHover(hoveringIndex: hoveringIndex, isInCenterArea: isInCenterArea, targetApp: originalApp)
            } else {
                clearHoveringState()
                pendingDropIndex = hoveringIndex
            }
        } else if case .app = dragging {
            handleAppToAppHover(hoveringIndex: hoveringIndex, isInCenterArea: isInCenterArea, targetApp: targetApp)
        } else {
            clearHoveringState()
            pendingDropIndex = hoveringIndex
        }
    }
    
    private func handleAppToAppHover(hoveringIndex: Int, isInCenterArea: Bool, targetApp: AppInfo) {
        let now = Date()
        let candidateChanged = folderHoverCandidateIndex != hoveringIndex || !isInCenterArea
        
        if candidateChanged {
            folderHoverCandidateIndex = isInCenterArea ? hoveringIndex : nil
            folderHoverBeganAt = isInCenterArea ? now : nil
            appStore.isDragCreatingFolder = false
            appStore.folderCreationTarget = nil
        }
        
        if isInCenterArea {
            appStore.isDragCreatingFolder = true
            appStore.folderCreationTarget = targetApp
            pendingDropIndex = nil
        } else {
            if !isInCenterArea || folderHoverCandidateIndex == nil {
                appStore.isDragCreatingFolder = false
                appStore.folderCreationTarget = nil
                pendingDropIndex = hoveringIndex
            } else {
                pendingDropIndex = nil
            }
        }
    }
    
    private func handleFolderHover(dragging: LaunchpadItem, hoveringIndex: Int, isInCenterArea: Bool) {
        if case .app = dragging {
            let now = Date()
            let candidateChanged = folderHoverCandidateIndex != hoveringIndex || !isInCenterArea
            
            if candidateChanged {
                folderHoverCandidateIndex = isInCenterArea ? hoveringIndex : nil
                folderHoverBeganAt = isInCenterArea ? now : nil
                appStore.isDragCreatingFolder = false
                appStore.folderCreationTarget = nil
            }
            
            if isInCenterArea {
                appStore.isDragCreatingFolder = true
                appStore.folderCreationTarget = nil
                pendingDropIndex = nil
            } else {
                if !isInCenterArea || folderHoverCandidateIndex == nil {
                    appStore.isDragCreatingFolder = false
                    appStore.folderCreationTarget = nil
                    pendingDropIndex = hoveringIndex
                } else {
                    pendingDropIndex = nil
                }
            }
        } else {
            clearHoveringState()
            pendingDropIndex = hoveringIndex
        }
    }
    
    private func clearHoveringState() {
        appStore.isDragCreatingFolder = false
        appStore.folderCreationTarget = nil
        pendingDropIndex = nil
        folderHoverCandidateIndex = nil
        folderHoverBeganAt = nil
    }
}


struct GridConfig {
    let isFullscreen: Bool
    
    init(isFullscreen: Bool = false) {
        self.isFullscreen = isFullscreen
    }
    
    var itemsPerPage: Int { 35 }
    var columns: Int { 7 }
    var rows: Int { 5 }
    
    let maxBounce: CGFloat = 80
    let pageSpacing: CGFloat = 100
    let rowSpacing: CGFloat = 16
    let columnSpacing: CGFloat = 24
    
    struct PageNavigation {
        let edgeFlipMargin: CGFloat = 2
        let autoFlipInterval: TimeInterval = 0.5 // 拖拽贴边翻页两次之间时间间隔
        let scrollPageThreshold: CGFloat = 0.75
        let scrollFinishThreshold: CGFloat = 0.5
    }
    
    let pageNavigation = PageNavigation()
    let folderCreateDwell: TimeInterval = 0
    
    var horizontalPadding: CGFloat { isFullscreen ? 0.05 : 0 }
    var topPadding: CGFloat { isFullscreen ? 0.05 : 0 }
    var bottomPadding: CGFloat { isFullscreen ? 0.1 : 0 }
    
    var gridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: columnSpacing), count: columns)
    }
}
 

//

struct DragPreviewItem: View {
    let item: LaunchpadItem
    let iconSize: CGFloat
    let labelWidth: CGFloat
    var scale: CGFloat = 1.2
    
    // 性能优化：使用计算属性避免状态修改
    private var displayIcon: NSImage {
        switch item {
        case .app(let app):
            return app.icon
        case .folder(let folder):
            return folder.icon(of: iconSize)
        case .empty:
            return item.icon
        }
    }

    var body: some View {
        switch item {
        case .app(let app):
            VStack(spacing: 6) {
                Image(nsImage: displayIcon)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: iconSize, height: iconSize)
                Text(app.name)
                    .font(.default)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: labelWidth)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .scaleEffect(scale)
            .animation(LNAnimations.easeInOut, value: scale)

        case .folder(let folder):
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: iconSize * 0.2)
                        .foregroundStyle(Color.clear)
                        .frame(width: iconSize * 0.8, height: iconSize * 0.8)
                        .glassEffect(.clear, in: RoundedRectangle(cornerRadius: iconSize * 0.2))
                        .shadow(radius: 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: iconSize * 0.2)
                                .stroke(Color.foundary.opacity(0.5), lineWidth: 2)
                        )
                    Image(nsImage: folder.icon(of: iconSize))
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .frame(width: iconSize, height: iconSize)
                }
                
                Text(folder.name)
                    .font(.default)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: labelWidth)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .scaleEffect(scale)
            .animation(LNAnimations.easeInOut, value: scale)
            
        case .empty:
            EmptyView()
        }
    }
}

// MARK: - 文件夹缩放+快速透明度过渡
private struct FolderZoomInModifier: ViewModifier, Animatable {
    var progress: CGFloat

    init(progress: CGFloat) {
        self.progress = max(0.01, progress)
    }

    var animatableData: CGFloat {
        get { progress }
        set { progress = max(0.01, min(1, newValue)) }
    }

    func body(content: Content) -> some View {
        let safe = max(0.01, progress)
        return content
            .scaleEffect(safe)
            .opacity(min(1, safe / 0.9))
    }
}

private struct FolderZoomOutModifier: ViewModifier, Animatable {
    var progress: CGFloat

    init(progress: CGFloat) {
        self.progress = max(0.01, progress)
    }

    var animatableData: CGFloat {
        get { progress }
        set { progress = max(0.01, min(1, newValue)) }
    }

    func body(content: Content) -> some View {
        let safe = max(0.01, progress)
        return content
            .scaleEffect(safe)
            .opacity(max(0, (safe - 0.1) / 0.9))
    }
}

private extension AnyTransition {
    static var scaleWithEarlyOpacity: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: FolderZoomInModifier(progress: 0.01),
                identity: FolderZoomInModifier(progress: 1)
            ),
            removal: .modifier(
                active: FolderZoomOutModifier(progress: 0.01),
                identity: FolderZoomOutModifier(progress: 1)
            )
        )
    }
}

func arrowDelta(for keyCode: UInt16) -> (dx: Int, dy: Int)? {
    switch keyCode {
    case 123: return (-1, 0) // left
    case 124: return (1, 0)  // right
    case 126: return (0, -1) // up
    case 125: return (0, 1)  // down
    default: return nil
    }
}
