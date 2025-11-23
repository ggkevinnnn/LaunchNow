import SwiftUI
import Combine
import AppKit

// MARK: - LaunchpadItem extension
extension LaunchpadItem {
    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }
}

// MARK: - 简化的翻页管理器
private class PageFlipManager: ObservableObject {
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
}

struct LaunchpadView: View {
    @ObservedObject var appStore: AppStore
    @State private var keyMonitor: Any?
    @State private var windowObserver: NSObjectProtocol?
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
    @State private var globalMouseUpMonitor: Any? = nil
    @State private var gridOriginInWindow: CGPoint = .zero
    @State private var currentContainerSize: CGSize = .zero
    @State private var currentColumnWidth: CGFloat = 0
    @State private var currentAppHeight: CGFloat = 0
    @State private var currentIconSize: CGFloat = 0
    
    // Added states for drag original index and flagsChanged monitor
    @State private var dragOriginalIndex: Int? = nil
    @State private var flagsMonitor: Any? = nil
    
    // 新增：外部网格落点淡入标记
    @State private var lastDroppedItemID: String? = nil
    
    // 性能优化：使用静态缓存避免状态修改问题
    private static var geometryCache: [String: CGPoint] = [:]
    private static var lastGeometryUpdate: Date = Date.distantPast
    private let geometryCacheTimeout: TimeInterval = 0.1 // 100ms缓存超时
    
    // 性能监控
    @State private var performanceMetrics: [String: TimeInterval] = [:]
    @State private var isHandoffDragging: Bool = false
    @State private var isUserSwiping: Bool = false
    @State private var accumulatedScrollX: CGFloat = 0
    @State private var wheelAccumulatedSinceFlip: CGFloat = 0
    @State private var wheelLastDirection: Int = 0
    @State private var wheelLastFlipAt: Date? = nil
    private let wheelFlipCooldown: TimeInterval = 0.15

    private var isFolderOpen: Bool { appStore.openFolder != nil }
    
    private var config: GridConfig {
        GridConfig(isFullscreen: appStore.isFullscreenMode)
    }
    
    var filteredItems: [LaunchpadItem] {
        guard !appStore.searchText.isEmpty else { return appStore.items }
        
        var result: [LaunchpadItem] = []
        var searchedApps = Set<String>() // 用于去重，避免重复显示同一个应用
        
        // 首先搜索主界面上的项目
        for item in appStore.items {
            switch item {
            case .app(let app):
                if app.name.localizedCaseInsensitiveContains(appStore.searchText) {
                    result.append(.app(app))
                    searchedApps.insert(app.url.path)
                }
            case .folder(let folder):
                // 检查文件夹名称
                if folder.name.localizedCaseInsensitiveContains(appStore.searchText) {
                    result.append(.folder(folder))
                }
                
                // 检查文件夹内的应用，如果匹配则提取出来直接显示
                let matchingApps = folder.apps.filter { app in
                    app.name.localizedCaseInsensitiveContains(appStore.searchText)
                }
                for app in matchingApps {
                    if !searchedApps.contains(app.url.path) {
                        // 确保应用对象有效且图标可用
                        let icon = app.icon.size.width > 0 ? app.icon : NSWorkspace.shared.icon(forFile: app.url.path)
                        let validApp = AppInfo(
                            name: app.name,
                            icon: icon,
                            url: app.url
                        )
                        result.append(.app(validApp))
                        searchedApps.insert(app.url.path)
                    }
                }
                
            case .empty:
                break
            }
        }
        
        return result
    }
    
    var pages: [[LaunchpadItem]] {
        let items = draggingItem != nil ? visualItems : filteredItems
        return makePages(from: items)
    }
    
    private var currentItems: [LaunchpadItem] {
        draggingItem != nil ? visualItems : filteredItems
    }
    
    private var visualItems: [LaunchpadItem] {
        guard let dragging = draggingItem, let pending = pendingDropIndex else { return filteredItems }
        let itemsPerPage = config.itemsPerPage
        var pageSlices: [[LaunchpadItem]] = makePages(from: filteredItems)

        let sourcePage = pageSlices.firstIndex { $0.contains(dragging) }
        let sourceIndexInPage = sourcePage.flatMap { pageSlices[$0].firstIndex(of: dragging) }
        let targetPage = max(0, pending / itemsPerPage)
        let localIndexDesired = pending % itemsPerPage

        if let sPage = sourcePage, sPage == targetPage, let sIdx = sourceIndexInPage {
            pageSlices[sPage].remove(at: sIdx)
        }

        while pageSlices.count <= targetPage { pageSlices.append([]) }
        let localIndex = max(0, min(localIndexDesired, pageSlices[targetPage].count))
        pageSlices[targetPage].insert(dragging, at: localIndex)

        var p = targetPage
        while p < pageSlices.count {
            if pageSlices[p].count > itemsPerPage {
                let spilled = pageSlices[p].removeLast()
                if p + 1 >= pageSlices.count { pageSlices.append([]) }
                pageSlices[p + 1].insert(spilled, at: 0)
                p += 1
            } else {
                p += 1
            }
        }
        return pageSlices.flatMap { $0 }
    }
    
    private func makePages(from items: [LaunchpadItem]) -> [[LaunchpadItem]] {
        guard !items.isEmpty else { return [] }
        return stride(from: 0, to: items.count, by: config.itemsPerPage).map { start in
            let end = min(start + config.itemsPerPage, items.count)
            return Array(items[start..<end])
        }
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
                            .foregroundStyle(.placeholder.opacity(0.5))
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
                        let hStackOffset = -CGFloat(appStore.currentPage) * effectivePageWidth
                        ZStack(alignment: .topLeading) {
                            // 内容
                            HStack(spacing: config.pageSpacing) {
                                ForEach(pages.indices, id: \.self) { index in
                                    VStack(alignment: .leading, spacing: 0) {
                                        // 在网格上方添加动态padding
                                        if config.isFullscreen {
                                            Spacer()
                                                .frame(height: actualTopPadding)
                                        }
                                        LazyVGrid(columns: config.gridItems, spacing: config.rowSpacing) {
                                            ForEach(Array(pages[index].enumerated()), id: \.element.id) { (localOffset, item) in
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
                                        .animation(LNAnimations.springFast, value: pendingDropIndex)
                                        .animation(LNAnimations.springFast, value: appStore.gridRefreshTrigger)
                                        .id("grid_\(index)_\(appStore.gridRefreshTrigger.uuidString)")
                                        .frame(maxHeight: .infinity, alignment: .top)
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
                        .onAppear { }
                        
                        .onChange(of: appStore.handoffDraggingApp) {
                            if appStore.openFolder == nil, appStore.handoffDraggingApp != nil {
                                startHandoffDragIfNeeded(geo: geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                        }
                        .onChange(of: appStore.openFolder) {
                            if appStore.openFolder == nil, appStore.handoffDraggingApp != nil {
                                startHandoffDragIfNeeded(geo: geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                        }
                        .onChange(of: appStore.currentPage) {
                            DispatchQueue.main.async {
                                captureGridGeometry(geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                                
                                // 智能预加载当前页面和相邻页面的图标
                                AppCacheManager.shared.smartPreloadIcons(
                                    for: appStore.items,
                                    currentPage: appStore.currentPage,
                                    itemsPerPage: config.itemsPerPage
                                )
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
        .glassEffect(.regular , in: RoundedRectangle(cornerRadius: appStore.isFullscreenMode ? 0 : 30))
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
                            withAnimation(LNAnimations.springFast) {
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
                    GeometryReader { proxy in
                        let targetWidth = proxy.size.width * 0.7
                        let targetHeight = proxy.size.height * 0.7
                        let folderId = openFolder.id
                        
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
                                if let idx = appStore.folders.firstIndex(where: { $0.id == folderId }) {
                                    appStore.folders[idx] = newValue
                                }
                            }
                        )
                        
                        FolderView(
                            appStore: appStore,
                            folder: folderBinding,
                            preferredIconSize: currentIconSize,
                            onClose: {
                                let closingFolder = appStore.openFolder
                                withAnimation(LNAnimations.springFast) {
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
                        .environmentObject(appStore)
                        .frame(width: targetWidth, height: targetHeight)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .id("folder_\(folderId)") // 使用稳定ID，避免每次更新导致视图重建
                        
                    }
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
             setupWindowHiddenObserver()
             // 监听全局鼠标抬起，确保拖拽状态被正确清理（窗口外释放时）
             if let existing = globalMouseUpMonitor { NSEvent.removeMonitor(existing) }
             globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
                 if handoffEventMonitor != nil || draggingItem != nil {
                     finalizeHandoffDrag()
                 }
                 DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                     if draggingItem != nil {
                         draggingItem = nil
                         pendingDropIndex = nil
                         appStore.isDragCreatingFolder = false
                         appStore.folderCreationTarget = nil
                         pageFlipManager.isCooldown = false
                         isHandoffDragging = false
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
            [keyMonitor, handoffEventMonitor].forEach { monitor in
                if let monitor = monitor { NSEvent.removeMonitor(monitor) }
            }
            if let monitor = globalMouseUpMonitor { NSEvent.removeMonitor(monitor) }
            [windowObserver, windowHiddenObserver].forEach { observer in
                if let observer = observer { NotificationCenter.default.removeObserver(observer) }
            }
            if let monitor = flagsMonitor { NSEvent.removeMonitor(monitor) }
            flagsMonitor = nil
            keyMonitor = nil
            handoffEventMonitor = nil
            globalMouseUpMonitor = nil
            windowObserver = nil
            windowHiddenObserver = nil
        }
    }
    
    private func launchApp(_ app: AppInfo) {
        AppDelegate.shared?.hideWindow()
        DispatchQueue.main.asyncAfter(deadline: .now()) {
            NSWorkspace.shared.open(app.url)
        }
    }
    
    private func handleItemTap(_ item: LaunchpadItem) {
        guard draggingItem == nil else { return }
        switch item {
        case .app(let app):
            launchApp(app)
        case .folder(let folder):
            withAnimation(LNAnimations.springFast) {
                appStore.openFolder = folder
            }
        case .empty:
            break
        }
    }
    
    

    // MARK: - Handoff drag from folder
    private func startHandoffDragIfNeeded(geo: GeometryProxy, columnWidth: CGFloat, appHeight: CGFloat, iconSize: CGFloat) {
        guard draggingItem == nil, let app = appStore.handoffDraggingApp else { return }
        // 更新几何上下文
        captureGridGeometry(geo, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)

        // 初始位置：屏幕 -> 网格局部
        let screenPoint = appStore.handoffDragScreenLocation ?? NSEvent.mouseLocation
        let localPoint = convertScreenToGrid(screenPoint)

        var tx = Transaction(); tx.disablesAnimations = true
        withTransaction(tx) { draggingItem = .app(app) }
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

    private func handleHandoffDragMove(to localPoint: CGPoint) {
        // 复用与普通拖拽完全一致的更新逻辑
        applyDragUpdate(at: localPoint,
                        containerSize: currentContainerSize,
                        columnWidth: currentColumnWidth,
                        appHeight: currentAppHeight,
                        iconSize: currentIconSize)
    }

    private func finalizeHandoffDrag() {
        isSettlingDrop = true
        guard let dragging = draggingItem else { return }
        defer {
            if let monitor = handoffEventMonitor { NSEvent.removeMonitor(monitor); handoffEventMonitor = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                draggingItem = nil
                pendingDropIndex = nil
                clampSelection()
                // 重置翻页状态
                pageFlipManager.isCooldown = false
                isHandoffDragging = false
                // 重置拖拽创建文件夹相关状态，确保后续拖拽功能正常
                appStore.isDragCreatingFolder = false
                appStore.folderCreationTarget = nil
                // 与普通拖拽结束保持一致的清理
                appStore.cleanupUnusedNewPage()
                appStore.removeEmptyPages()
                appStore.pruneEmptyFolders()
                appStore.saveAllOrder()
                // 触发网格刷新，确保拖拽手势被正确重新添加
                appStore.triggerGridRefresh()
                isSettlingDrop = false
                dragPreviewOpacity = 1.0
            }
        }
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

        withAnimation(LNAnimations.dragSnap) {
            dragPreviewOpacity = 0.0
        }
        // 使用统一的拖拽结束处理逻辑
        finalizeDragOperation(containerSize: currentContainerSize, columnWidth: currentColumnWidth, appHeight: currentAppHeight, iconSize: currentIconSize)
        
        // 立即触发网格刷新，确保拖拽手势被正确重新添加
        appStore.triggerGridRefresh()
    }

    private func navigateToPage(_ targetPage: Int, animated: Bool = true) {
        guard targetPage >= 0 && targetPage < pages.count else { return }
        if animated {
            withAnimation(LNAnimations.springFast) {
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
            isSearchFieldFocused = true
            if !appStore.apps.isEmpty {
                appStore.applyOrderAndFolders()
            }
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
                withAnimation(LNAnimations.springFast) {
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
            AppDelegate.shared?.hideWindow()
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
            let shouldAllowHover = draggingItem == nil

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
                shouldAllowHover: shouldAllowHover,
                externalScale: isCenterCreatingTarget ? 1.2 : nil,
                onTap: { if draggingItem == nil { handleItemTap(item) } }
            )
            .environmentObject(appStore)
            .frame(height: appHeight)
            .matchedGeometryEffect(id: item.id, in: reorderNamespace)
            // 保持稳定的视图身份，避免在文件夹更新后中断拖拽手势
            .id(item.id)
            
            // 统一：对“刚落下的项”做淡入（无论是否可拖拽/是否在搜索模式）
            let baseWithFade = base
                .opacity((lastDroppedItemID == item.id) ? 0 : 1)
                .animation(LNAnimations.itemAppear, value: lastDroppedItemID)

            if appStore.searchText.isEmpty && !isFolderOpen {
                let isDraggingThisTile = (draggingItem == item)

                baseWithFade
                    // 拖拽中的该 tile 隐形
                    .opacity((isDraggingThisTile && !isSettlingDrop) ? 0 : 1)
                    .animation(LNAnimations.itemAppear, value: isSettlingDrop)
                    .animation(LNAnimations.itemAppear, value: pendingDropIndex)
                    .allowsHitTesting(!isDraggingThisTile)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .named("grid"))
                            .onChanged { value in
                                handleDragChange(value, item: item, in: containerSize, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                            .onEnded { _ in
                                guard draggingItem != nil else { return }
                                
                                // 使用统一的拖拽结束处理逻辑
                                finalizeDragOperation(containerSize: containerSize, columnWidth: columnWidth, appHeight: appHeight, iconSize: iconSize)
                            }
                    )
            } else {
                baseWithFade
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
        
        // 异步更新缓存，避免在视图更新期间修改状态
        DispatchQueue.main.async {
            Self.geometryCache[cacheKey] = center
            Self.lastGeometryUpdate = now
        }
        
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
        
        // 异步更新缓存，避免在视图更新期间修改状态
        DispatchQueue.main.async {
            Self.geometryCache[cacheKey] = targetCenter
            Self.lastGeometryUpdate = now
        }
        
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
        guard !isFolderOpen else { return }
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

        // Trackpad precise scroll: accumulate and flip after threshold
        // Ignore momentum phase to ensure only one flip per gesture
        if isMomentum { return }
        let delta = abs(deltaX) >= abs(deltaY) ? deltaX : -deltaY // vertical swipes map to horizontal
        switch phase {
        case .began:
            isUserSwiping = true
            accumulatedScrollX = 0
        case .changed:
            isUserSwiping = true
            accumulatedScrollX += delta
        case .ended, .cancelled:
            // 使灵敏度越大阈值越小，以符合直觉（与鼠标滚轮一致）
            // 归一到默认值 0.15：threshold = pageWidth * (0.0225 / sensitivity)
            // 当 sensitivity=0.15 时，阈值为 0.15*pageWidth；越大则更灵敏（阈值更小）
            let threshold = pageWidth * (0.0225 / max(appStore.scrollSensitivity, 0.001))
            if accumulatedScrollX <= -threshold {
                navigateToNextPage()
            } else if accumulatedScrollX >= threshold {
                navigateToPreviousPage()
            }
            accumulatedScrollX = 0
            isUserSwiping = false
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

        override func scrollWheel(with event: NSEvent) {
            // Prefer primary phase; fallback to momentum
            let phase = event.phase != [] ? event.phase : event.momentumPhase
            let isMomentum = event.momentumPhase != []
            let isPreciseOrTrackpad = event.hasPreciseScrollingDeltas || event.phase != [] || event.momentumPhase != []
            onScroll?(event.scrollingDeltaX,
                      event.scrollingDeltaY,
                      phase,
                      isMomentum,
                      isPreciseOrTrackpad)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor = eventMonitor { NSEvent.removeMonitor(monitor); eventMonitor = nil }
            // 全局监听当前窗口的滚动事件，不消费事件
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                let phase = event.phase != [] ? event.phase : event.momentumPhase
                let isMomentum = event.momentumPhase != []
                let isPreciseOrTrackpad = event.hasPreciseScrollingDeltas || event.phase != [] || event.momentumPhase != []
                self?.onScroll?(event.scrollingDeltaX,
                                event.scrollingDeltaY,
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
        
        // 检查翻页冷却状态
        pageFlipManager.autoFlipInterval = config.pageNavigation.autoFlipInterval
        guard pageFlipManager.canFlip() else { return false }
                
        if point.x <= edgeMargin && appStore.currentPage > 0 {
            navigateToPreviousPage()
            pageFlipManager.recordFlip()
            return true
        } else if point.x >= containerSize.width - edgeMargin {
            // 检查是否需要创建新页面
            let nextPage = appStore.currentPage + 1
            let itemsPerPage = config.itemsPerPage
            let nextPageStart = nextPage * itemsPerPage
            
            // 如果拖拽到新页面，确保有足够的空间
            if nextPageStart >= currentItems.count {
                let neededItems = nextPageStart + itemsPerPage - currentItems.count
                for _ in 0..<neededItems {
                    appStore.items.append(.empty(UUID().uuidString))
                }
            }
            
            navigateToNextPage()
            pageFlipManager.recordFlip()
            return true
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
        
        if point.x <= edgeMargin && appStore.currentPage > 0 {
            let prevPage = appStore.currentPage - 1
            let prevPageStart = prevPage * itemsPerPage
            let prevPageEnd = min(prevPageStart + itemsPerPage, currentItems.count)
            return max(prevPageStart, prevPageEnd - 1)
        } else if point.x >= containerSize.width - edgeMargin {
            let nextPage = appStore.currentPage + 1
            let nextPageStart = nextPage * itemsPerPage
            
            // 如果拖拽到新页面，确保能够正确预测到新页面的第一个位置
            if nextPageStart >= currentItems.count {
                // 拖拽到全新页面，返回新页面的第一个位置
                return nextPageStart
            } else {
                return min(nextPageStart, currentItems.count - 1)
            }
        } else {
            if point.x <= edgeMargin {
                return appStore.currentPage * itemsPerPage
            } else {
                let currentPageEnd = min((appStore.currentPage + 1) * itemsPerPage, currentItems.count)
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
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { draggingItem = item }
            dragOriginalIndex = filteredItems.firstIndex(of: item)
            isKeyboardNavigationActive = false
            appStore.isDragCreatingFolder = false
            appStore.folderCreationTarget = nil
            dragPreviewPosition = value.location
        }
        applyDragUpdate(at: value.location,
                        containerSize: containerSize,
                        columnWidth: columnWidth,
                        appHeight: appHeight,
                        iconSize: iconSize)
    }

    // 统一的拖拽结束处理逻辑（普通拖拽与接力拖拽共用）
    private func finalizeDragOperation(containerSize: CGSize, columnWidth: CGFloat, appHeight: CGFloat, iconSize: CGFloat) {
        guard let dragging = draggingItem else { return }
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
                    withAnimation(LNAnimations.dragSnap) {
                        dragPreviewPosition = targetCenter
                        dragPreviewScale = 1.0
                        dragPreviewOpacity = 0.0
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    draggingItem = nil
                    pendingDropIndex = nil
                    appStore.isDragCreatingFolder = false
                    appStore.folderCreationTarget = nil
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
                if let insertAt = filteredItems.firstIndex(of: .app(targetApp)) {
                    let newFolder = appStore.createFolder(with: [app, targetApp], insertAt: insertAt)
                    if let folderIndex = filteredItems.firstIndex(of: .folder(newFolder)) {
                        let targetCenter = cellCenter(for: folderIndex,
                                                      in: containerSize,
                                                      pageIndex: appStore.currentPage,
                                                      columnWidth: columnWidth,
                                                      appHeight: appHeight)
                        withAnimation(LNAnimations.dragSnap) {
                            dragPreviewPosition = targetCenter
                            dragPreviewScale = 1.0
                            dragPreviewOpacity = 0.0
                        }
                    }
                } else {
                    let newFolder = appStore.createFolder(with: [app, targetApp])
                    if let folderIndex = filteredItems.firstIndex(of: .folder(newFolder)) {
                        let targetCenter = cellCenter(for: folderIndex,
                                                      in: containerSize,
                                                      pageIndex: appStore.currentPage,
                                                      columnWidth: columnWidth,
                                                      appHeight: appHeight)
                        withAnimation(LNAnimations.dragSnap) {
                            dragPreviewPosition = targetCenter
                            dragPreviewScale = 1.0
                            dragPreviewOpacity = 0.0
                        }
                    }
                }
                // 文件夹创建完成后不需要额外淡入
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    draggingItem = nil
                    pendingDropIndex = nil
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
                   filteredItems.indices.contains(hoveringIndex),
                   case .folder(let folder) = filteredItems[hoveringIndex] {
                    appStore.addAppToFolder(app, folder: folder)
                    let targetCenter = cellCenter(for: hoveringIndex,
                                                  in: containerSize,
                                                  pageIndex: appStore.currentPage,
                                                  columnWidth: columnWidth,
                                                  appHeight: appHeight)
                    withAnimation(LNAnimations.dragSnap) {
                        dragPreviewPosition = targetCenter
                        dragPreviewScale = 1.0
                        dragPreviewOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        draggingItem = nil
                        pendingDropIndex = nil
                        isSettlingDrop = false
                        dragPreviewOpacity = 1.0
                        clampSelection()
                    }
                    return
                }
            }
            appStore.isDragCreatingFolder = false
            appStore.folderCreationTarget = nil
            return
        }
        
        // 处理普通拖拽逻辑
        if let finalIndex = pendingDropIndex,
           let _ = filteredItems.firstIndex(of: dragging) {
            // 检查是否为跨页拖拽
            let sourceIndexInItems = appStore.items.firstIndex(of: dragging) ?? 0
            let targetPage = finalIndex / config.itemsPerPage
            let sourcePage = sourceIndexInItems / config.itemsPerPage
            
            // 视觉吸附到目标格中心
            let dropDisplayIndex = finalIndex
            let finalPage = pageOf(index: dropDisplayIndex)
            let targetCenter = cellCenter(for: dropDisplayIndex,
                                          in: containerSize,
                                          pageIndex: finalPage,
                                          columnWidth: columnWidth,
                                          appHeight: appHeight)
            withAnimation(LNAnimations.dragSnap) {
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
                let pageStart = (finalIndex / config.itemsPerPage) * config.itemsPerPage
                let pageEnd = min(pageStart + config.itemsPerPage, appStore.items.count)
                var newItems = appStore.items
                var pageSlice = Array(newItems[pageStart..<pageEnd])
                let localFrom = sourceIndexInItems - pageStart
                let localTo = max(0, min(finalIndex - pageStart, pageSlice.count - 1))
                let moving = pageSlice.remove(at: localFrom)
                pageSlice.insert(moving, at: localTo)
                newItems.replaceSubrange(pageStart..<pageEnd, with: pageSlice)
                withAnimation(LNAnimations.springFast) {
                    appStore.items = newItems
                }
                appStore.saveAllOrder()
            } else {
                // 跨页拖拽：使用级联插入逻辑
                appStore.moveItemAcrossPagesWithCascade(item: dragging, to: finalIndex)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                draggingItem = nil
                pendingDropIndex = nil
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
            // 兜底逻辑：如果没有有效的目标索引，将应用放置到当前页的末尾
            if let draggingIndex = filteredItems.firstIndex(of: dragging) {
                let currentPageStart = appStore.currentPage * config.itemsPerPage
                let currentPageEnd = min(currentPageStart + config.itemsPerPage, appStore.items.count)
                let targetIndex = currentPageEnd
                
                // 设置“落点淡入”的标记
                lastDroppedItemID = dragging.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    lastDroppedItemID = nil
                }
                
                // 使用级联插入确保应用能正确放置
                appStore.moveItemAcrossPagesWithCascade(item: dragging, to: targetIndex)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    draggingItem = nil
                    pendingDropIndex = nil
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
    }

    // 统一的拖拽更新逻辑（普通拖拽与接力拖拽共用）
    private func applyDragUpdate(at point: CGPoint,
                                 containerSize: CGSize,
                                 columnWidth: CGFloat,
                                 appHeight: CGFloat,
                                 iconSize: CGFloat) {
        // 性能优化：减少频繁的位置更新
        let distance = sqrt(pow(dragPreviewPosition.x - point.x, 2) + pow(dragPreviewPosition.y - point.y, 2))
        if distance < 2.0 { return } // 如果移动距离小于2像素，跳过更新
        
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
            clearHoveringState()
            pendingDropIndex = hoveringIndex
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
        let edgeFlipMargin: CGFloat = 15
        let autoFlipInterval: TimeInterval = 0.8 // 拖拽贴边翻页两次之间间隔0.8秒
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
            .animation(LNAnimations.springFast, value: scale)

        case .folder(let folder):
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: iconSize * 0.2)
                        .foregroundStyle(Color.clear)
                        .frame(width: iconSize * 0.8, height: iconSize * 0.8)
                        .glassEffect(in: RoundedRectangle(cornerRadius: iconSize * 0.2))
                        .shadow(radius: 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: iconSize * 0.2)
                                .stroke(Color.foundary.opacity(0.5), lineWidth: 1)
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
            .animation(LNAnimations.springFast, value: scale)
            
        case .empty:
            EmptyView()
        }
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

