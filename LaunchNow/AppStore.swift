import Foundation
import AppKit
import Combine
import SwiftData
import UniformTypeIdentifiers

final class AppStore: ObservableObject {
    @Published var showWelcomeSheet: Bool = false
    @Published var apps: [AppInfo] = []
    @Published var folders: [FolderInfo] = []
    @Published var items: [LaunchpadItem] = []
    @Published var isSetting = false
    @Published var currentPage = 0
    @Published var searchText: String = ""
    @Published var isFullscreenMode: Bool = false {
        didSet {
            UserDefaults.standard.set(isFullscreenMode, forKey: "isFullscreenMode")
            DispatchQueue.main.async { [weak self] in
                if let appDelegate = AppDelegate.shared {
                    appDelegate.updateWindowMode(isFullscreen: self?.isFullscreenMode ?? false)
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.triggerGridRefresh()
            }
        }
    }
    
    @Published var scrollSensitivity: Double = 0.15 {
        didSet {
            UserDefaults.standard.set(scrollSensitivity, forKey: "scrollSensitivity")
        }
    }
    
    @Published var iconScale: Double = 0.8 {
        didSet {
            UserDefaults.standard.set(iconScale, forKey: "iconScale")
            DispatchQueue.main.async { [weak self] in
                self?.triggerGridRefresh()
            }
        }
    }
    
    @Published var showAppNameBelowIcon: Bool = true {
        didSet {
            UserDefaults.standard.set(showAppNameBelowIcon, forKey: "showAppNameBelowIcon")
            DispatchQueue.main.async { [weak self] in
                self?.triggerGridRefresh()
            }
        }
    }
    
    // Option 模式：仅允许创建/加入文件夹，禁止网格让位与插入
    @Published var isOptionFolderMode: Bool = false
    
    // 缓存管理器
    private let cacheManager = AppCacheManager.shared
    
    // 文件夹相关状态
    @Published var openFolder: FolderInfo? = nil {
        didSet {
            // When closing an open folder, ensure we reset editing/dragging states so grid drag works again
            if oldValue != nil && openFolder == nil {
                // End any folder-name editing session
                isFolderNameEditing = false
                // Exit option mode
                isOptionFolderMode = false
                // Clear any in-progress folder creation state
                isDragCreatingFolder = false
                folderCreationTarget = nil
                // Clear drag handoff states ONLY if not currently handing off a drag
                if handoffDraggingApp == nil {
                    handoffDragScreenLocation = nil
                }
                // Do not reset handoffDraggingApp here to allow cross-surface drag handoff
                // Reset keyboard activation flag
                openFolderActivatedByKeyboard = false
                // Ensure UI refreshes and grid becomes interactive again
                triggerFolderUpdate()
                triggerGridRefresh()
            }
        }
    }
    @Published var isDragCreatingFolder = false
    @Published var folderCreationTarget: AppInfo? = nil
    @Published var openFolderActivatedByKeyboard: Bool = false
    @Published var isFolderNameEditing: Bool = false
    @Published var handoffDraggingApp: AppInfo? = nil
    @Published var handoffDragScreenLocation: CGPoint? = nil
    
    // 触发器
    @Published var folderUpdateTrigger: UUID = UUID()
    @Published var gridRefreshTrigger: UUID = UUID()
    
    var modelContext: ModelContext?
    
    private var isConfigured: Bool = false

    // MARK: - Auto rescan (FSEvents)
    private var fsEventStream: FSEventStreamRef?
    private var pendingChangedAppPaths: Set<String> = []
    private var pendingForceFullScan: Bool = false
    private let fullRescanThreshold: Int = 50

    // 状态标记
    private var hasPerformedInitialScan: Bool = false
    private var cancellables: Set<AnyCancellable> = []
    private var hasAppliedOrderFromStore: Bool = false
    
    // 后台刷新队列与节流
    private let refreshQueue = DispatchQueue(label: "app.store.refresh", qos: .userInitiated)
    private var gridRefreshWorkItem: DispatchWorkItem?
    private var rescanWorkItem: DispatchWorkItem?
    private let fsEventsQueue = DispatchQueue(label: "app.store.fsevents")
    
    // 计算属性
    private var itemsPerPage: Int { 35 }
    
    private let systemDefaultSearchPaths: [String] = [
        "/Applications",
        "\(NSHomeDirectory())/Applications",
        "/System/Applications",
        "/System/Cryptexes/App/System/Applications"
    ]

    @Published var defaultSearchPaths: [String] = [] {
        didSet {
            UserDefaults.standard.set(defaultSearchPaths, forKey: "defaultApplicationSearchPaths")
            if isConfigured {
                restartAutoRescan()
                scanApplicationsWithOrderPreservation()
                // 扫描应用是异步的，这里稍作延迟后清理空页面，确保扫描结果已应用
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.removeEmptyPages()
                }
            }
        }
    }

    @Published var customSearchPaths: [String] = [] {
        didSet {
            UserDefaults.standard.set(customSearchPaths, forKey: "customApplicationSearchPaths")
            // 路径发生变化时，重启自动扫描监听并触发一次智能扫描
            if isConfigured {
                restartAutoRescan()
                scanApplicationsWithOrderPreservation()
                // 扫描应用是异步的，这里稍作延迟后清理空页面，确保扫描结果已应用
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.removeEmptyPages()
                }
            }
        }
    }

    private func effectiveApplicationSearchPaths() -> [String] {
        let all = defaultSearchPaths + customSearchPaths
        // 去重 + 仅保留存在的目录
        var seen = Set<String>()
        var result: [String] = []
        for raw in all {
            let path = (raw as NSString).expandingTildeInPath
            if !seen.contains(path), FileManager.default.fileExists(atPath: path, isDirectory: nil) {
                seen.insert(path)
                result.append(path)
            }
        }
        return result
    }

    init() {
        self.isFullscreenMode = UserDefaults.standard.bool(forKey: "isFullscreenMode")
        self.scrollSensitivity = UserDefaults.standard.double(forKey: "scrollSensitivity")
        // 如果没有保存过设置，使用默认值
        if self.scrollSensitivity == 0.0 {
            self.scrollSensitivity = 0.15
        }
        let savedIconScale = UserDefaults.standard.object(forKey: "iconScale") as? Double
        if let savedIconScale, savedIconScale > 0 {
            self.iconScale = savedIconScale
        } else {
            self.iconScale = 0.8
        }
        self.showAppNameBelowIcon = UserDefaults.standard.object(forKey: "showAppNameBelowIcon") as? Bool ?? true
        
        if let savedDefaults = UserDefaults.standard.array(forKey: "defaultApplicationSearchPaths") as? [String], !savedDefaults.isEmpty {
            self.defaultSearchPaths = savedDefaults
        } else {
            self.defaultSearchPaths = systemDefaultSearchPaths
        }
        if let savedCustom = UserDefaults.standard.array(forKey: "customApplicationSearchPaths") as? [String] {
            self.customSearchPaths = savedCustom
        }
    }

    func resetDefaultSearchPaths() {
        self.defaultSearchPaths = systemDefaultSearchPaths
        self.customSearchPaths = []
    }

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.isConfigured = true
        
        // 立即尝试加载持久化数据（如果已有数据）——不要过早设置标记，等待加载完成时设置
        if !hasAppliedOrderFromStore {
            loadAllOrder()
        }
        
        $apps
            .map { !$0.isEmpty }
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.hasAppliedOrderFromStore {
                    self.loadAllOrder()
                }
            }
            .store(in: &cancellables)
        
        // 监听items变化，自动保存排序
        $items
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self, !self.items.isEmpty else { return }
                // 延迟保存，避免频繁保存
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.saveAllOrder()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Order Persistence
    func applyOrderAndFolders() {
        self.loadAllOrder()
    }

    // MARK: - Initial scan (once)
    func performInitialScanIfNeeded() {
        // 先尝试加载持久化数据，避免被扫描覆盖（不提前设置标记）
        if !hasAppliedOrderFromStore {
            loadAllOrder()
        }
        
        // 然后进行扫描，但保持现有顺序
        hasPerformedInitialScan = true
        scanApplicationsWithOrderPreservation()
        
        // 扫描完成后生成缓存
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.generateCacheAfterScan()
        }
    }

    func scanApplications(loadPersistedOrder: Bool = true) {
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [AppInfo] = []
            var seenPaths = Set<String>()

            for path in self.effectiveApplicationSearchPaths() {
                let url = URL(fileURLWithPath: path)
                
                if let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let item as URL in enumerator {
                        let resolved = item.resolvingSymlinksInPath()
                        guard resolved.pathExtension == "app",
                              self.isValidApp(at: resolved),
                              !self.isInsideAnotherApp(resolved) else { continue }
                        if !seenPaths.contains(resolved.path) {
                            seenPaths.insert(resolved.path)
                            found.append(self.appInfo(from: resolved))
                        }
                    }
                }
            }

            let sorted = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.apps = sorted
                if loadPersistedOrder {
                    self.rebuildItems()
                    self.loadAllOrder()
                } else {
                    self.items = sorted.map { .app($0) }
                    self.saveAllOrder()
                }
                
                // 扫描完成后生成缓存
                self.generateCacheAfterScan()
            }
        }
    }
    
    /// 智能扫描应用：保持现有排序，新增应用放到最后，缺失应用移除，自动页面内补位
    func scanApplicationsWithOrderPreservation() {
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [AppInfo] = []
            var seenPaths = Set<String>()

            // 使用并发队列加速扫描
            let scanQueue = DispatchQueue(label: "app.scan", attributes: .concurrent)
            let group = DispatchGroup()
            let lock = NSLock()
            
            // 扫描所有应用
            for path in self.effectiveApplicationSearchPaths() {
                group.enter()
                scanQueue.async {
                    let url = URL(fileURLWithPath: path)
                    
                    if let enumerator = FileManager.default.enumerator(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    ) {
                        var localFound: [AppInfo] = []
                        var localSeenPaths = Set<String>()
                        
                        for case let item as URL in enumerator {
                            let resolved = item.resolvingSymlinksInPath()
                            guard resolved.pathExtension == "app",
                                  self.isValidApp(at: resolved),
                                  !self.isInsideAnotherApp(resolved) else { continue }
                            if !localSeenPaths.contains(resolved.path) {
                                localSeenPaths.insert(resolved.path)
                                localFound.append(self.appInfo(from: resolved))
                            }
                        }
                        
                        // 线程安全地合并结果
                        lock.lock()
                        found.append(contentsOf: localFound)
                        seenPaths.formUnion(localSeenPaths)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            
            group.wait()
            
            // 去重和排序 - 使用更安全的方法
            var uniqueApps: [AppInfo] = []
            var uniqueSeenPaths = Set<String>()
            
            for app in found {
                if !uniqueSeenPaths.contains(app.url.path) {
                    uniqueSeenPaths.insert(app.url.path)
                    uniqueApps.append(app)
                }
            }
            
            // 保持现有应用的顺序，只对新应用按名称排序
            var newApps: [AppInfo] = []
            var existingAppPaths = Set<String>()
            
            // 首先保持现有应用的顺序
            for app in self.apps {
                if uniqueApps.contains(where: { $0.url.path == app.url.path }) {
                    newApps.append(app)
                    existingAppPaths.insert(app.url.path)
                }
            }
            
            // 然后添加新应用，按名称排序
            let newAppPaths = uniqueApps.filter { !existingAppPaths.contains($0.url.path) }
            let sortedNewApps = newAppPaths.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            newApps.append(contentsOf: sortedNewApps)
            
            DispatchQueue.main.async {
                self.processScannedApplications(newApps)
                
                // 扫描完成后生成缓存
                self.generateCacheAfterScan()
            }
        }
    }
    
    /// 手动触发完全重新扫描（用于设置中的手动刷新）
    func forceFullRescan() {
        // 清除缓存
        cacheManager.clearAllCaches()
        
        hasPerformedInitialScan = false
        scanApplicationsWithOrderPreservation()
    }
    
    /// 处理扫描到的应用，智能匹配现有排序
    private func processScannedApplications(_ newApps: [AppInfo]) {
        // 保存当前 items 的顺序和结构
        let currentItems = self.items
        
        // 创建新应用列表，但保持现有顺序
        var updatedApps: [AppInfo] = []
        var newAppsToAdd: [AppInfo] = []
        
        // 第一步：保持现有应用的顺序，只更新仍然存在的应用
        for app in self.apps {
            if newApps.contains(where: { $0.url.path == app.url.path }) {
                // 应用仍然存在，保持原有位置
                updatedApps.append(app)
            } else {
                // 应用已删除，从所有相关位置移除
                self.removeDeletedApp(app)
            }
        }
        
        // 第二步：找出新增的应用
        for newApp in newApps {
            if !self.apps.contains(where: { $0.url.path == newApp.url.path }) {
                newAppsToAdd.append(newApp)
            }
        }
        
        // 第三步：将新增应用添加到末尾，保持现有应用顺序不变
        updatedApps.append(contentsOf: newAppsToAdd)
        
        // 更新应用列表
        self.apps = updatedApps
        
        // 第四步：智能重建项目列表，保持用户排序
        self.smartRebuildItemsWithOrderPreservation(currentItems: currentItems, newApps: newAppsToAdd)
        
        // 第五步：自动页面内补位
        self.compactItemsWithinPages()
        
        // 第六步：保存新的顺序
        self.saveAllOrder()
        
        // 触发界面更新
        self.triggerFolderUpdate()
        self.triggerGridRefresh()
    }
    
    /// 移除已删除的应用
    private func removeDeletedApp(_ deletedApp: AppInfo) {
        // 从文件夹中移除
        for folderIndex in self.folders.indices {
            self.folders[folderIndex].apps.removeAll { $0 == deletedApp }
        }
        
        // 清理空文件夹
        self.folders.removeAll { $0.apps.isEmpty }
        
        // 从顶层项目中移除，替换为空槽位
        for itemIndex in self.items.indices {
            if case let .app(app) = self.items[itemIndex], app == deletedApp {
                self.items[itemIndex] = .empty(UUID().uuidString)
            }
        }
        self.compactItemsWithinPages()
    }
    
    
    /// 严格保持现有顺序的重建方法
    private func rebuildItemsWithStrictOrderPreservation(currentItems: [LaunchpadItem]) {
        
        var newItems: [LaunchpadItem] = []
        let appsInFolders = Set(self.folders.flatMap { $0.apps })
        
        // 严格保持现有项目的顺序和位置
        for (_, item) in currentItems.enumerated() {
            switch item {
            case .folder(let folder):
                // 检查文件夹是否仍然存在
                if self.folders.contains(where: { $0.id == folder.id }) {
                    // 更新文件夹引用，保持原有位置
                    if let updatedFolder = self.folders.first(where: { $0.id == folder.id }) {
                        newItems.append(.folder(updatedFolder))
                    } else {
                        // 文件夹被删除，保持空槽位
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    // 文件夹被删除，保持空槽位
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case .app(let app):
                // 检查应用是否仍然存在
                if self.apps.contains(where: { $0.url.path == app.url.path }) {
                    if !appsInFolders.contains(app) {
                        // 应用仍然存在且不在文件夹中，保持原有位置
                        newItems.append(.app(app))
                    } else {
                        // 应用现在在文件夹中，保持空槽位
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    // 应用已删除，保持空槽位
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case .empty(let token):
                // 保持空槽位，维持页面布局
                newItems.append(.empty(token))
            }
        }
        
        // 添加新增的自由应用（不在任何文件夹中）到最后一页的最后面
        let existingAppPaths = Set(newItems.compactMap { item in
            if case let .app(app) = item { return app.url.path } else { return nil }
        })
        let newFreeApps = self.apps.filter { app in
            !appsInFolders.contains(app) && !existingAppPaths.contains(app.url.path)
        }
        if !newFreeApps.isEmpty {
            let itemsPerPage = self.itemsPerPage
            let currentPages = (newItems.count + itemsPerPage - 1) / itemsPerPage
            let lastPageStart = currentPages > 0 ? (currentPages - 1) * itemsPerPage : 0
            let lastPageRange = lastPageStart..<lastPageStart+itemsPerPage
            // 收集最后一页的empty槽索引
            var lastPageEmptyIndices: [Int] = []
            for idx in lastPageRange {
                if idx < newItems.count, case .empty = newItems[idx] {
                    lastPageEmptyIndices.append(idx)
                }
            }
            var appsToInsert = newFreeApps[...]
            // 先填充已有empty
            for idx in lastPageEmptyIndices.prefix(appsToInsert.count) {
                if let app = appsToInsert.first {
                    newItems[idx] = .app(app)
                    appsToInsert = appsToInsert.dropFirst()
                }
            }
            // 如果还有剩余app，先补空到完整页，再append到新页
            if !appsToInsert.isEmpty {
                let lastPageCount = newItems.count - lastPageStart
                if lastPageCount < itemsPerPage {
                    for _ in 0..<(itemsPerPage - lastPageCount) {
                        newItems.append(.empty(UUID().uuidString))
                    }
                }
                for app in appsToInsert {
                    newItems.append(.app(app))
                }
            }
        }
        
        self.items = newItems
    }
    
    private func insertAppsAtEndOfCurrentPageBeforeEmpties(items: inout [LaunchpadItem], apps: inout [AppInfo]) {
        guard !apps.isEmpty else { return }
        let p = self.itemsPerPage
        // 计算当前页的区间
        let pageStart = max(0, currentPage) * p
        let pageEnd = pageStart + p

        // 确保 items 至少覆盖当前页范围，不足则以 empty 填充
        if items.count < pageEnd {
            let need = pageEnd - items.count
            for _ in 0..<need { items.append(.empty(UUID().uuidString)) }
        }

        // 在当前页范围内找到第一个 empty 的索引
        var firstEmptyIndex: Int? = nil
        if pageStart < items.count {
            let end = min(pageEnd, items.count)
            var i = pageStart
            while i < end {
                if case .empty = items[i] {
                    firstEmptyIndex = i
                    break
                }
                i += 1
            }
        }

        guard let startIndex = firstEmptyIndex else { return }

        // 依次用新应用替换 empty，直到没有 empty 或没有新应用
        var insertIndex = startIndex
        while insertIndex < pageEnd, !apps.isEmpty {
            if case .empty = items[insertIndex] {
                let app = apps.removeFirst()
                items[insertIndex] = .app(app)
            }
            insertIndex += 1
        }
    }
    
    /// 智能重建项目列表，保持用户排序
    private func smartRebuildItemsWithOrderPreservation(currentItems: [LaunchpadItem], newApps: [AppInfo]) {
        
        // 保存当前的持久化数据，但不立即加载（避免覆盖现有顺序）
        let hasPersistedData = self.hasPersistedOrderData()
        
        if hasPersistedData {
            
            // 智能合并现有顺序和持久化数据
            self.mergeCurrentOrderWithPersistedData(currentItems: currentItems, newApps: newApps)
        } else {
            
            // 没有持久化数据时，使用扫描结果重新构建
            self.rebuildFromScannedApps(newApps: newApps)
        }
        
    }
    
    /// 检查是否有持久化数据
    private func hasPersistedOrderData() -> Bool {
        guard let modelContext = self.modelContext else { return false }
        
        do {
            let pageEntries = try modelContext.fetch(FetchDescriptor<PageEntryData>())
            let topItems = try modelContext.fetch(FetchDescriptor<TopItemData>())
            return !pageEntries.isEmpty || !topItems.isEmpty
        } catch {
            return false
        }
    }
    
    /// 智能合并现有顺序和持久化数据
    private func mergeCurrentOrderWithPersistedData(currentItems: [LaunchpadItem], newApps: [AppInfo]) {
        
        // 保存当前的项目顺序
        let currentOrder = currentItems
        
        // 加载持久化数据，但只更新文件夹信息
        self.loadFoldersFromPersistedData()
        
        // 重建项目列表，严格保持现有顺序
        var newItems: [LaunchpadItem] = []
        let appsInFolders = Set(self.folders.flatMap { $0.apps })
        
        // 第一步：处理现有项目，保持顺序
        for (_, item) in currentOrder.enumerated() {
            switch item {
            case .folder(let folder):
                // 检查文件夹是否仍然存在
                if self.folders.contains(where: { $0.id == folder.id }) {
                    // 更新文件夹引用，保持原有位置
                    if let updatedFolder = self.folders.first(where: { $0.id == folder.id }) {
                        newItems.append(.folder(updatedFolder))
                    } else {
                        // 文件夹被删除，保持空槽位
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    // 文件夹被删除，保持空槽位
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case .app(let app):
                // 检查应用是否仍然存在
                if self.apps.contains(where: { $0.url.path == app.url.path }) {
                    if !appsInFolders.contains(app) {
                        // 应用仍然存在且不在文件夹中，保持原有位置
                        newItems.append(.app(app))
                    } else {
                        // 应用现在在文件夹中，保持空槽位
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    // 应用已删除，保持空槽位
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case .empty(let token):
                // 保持空槽位，维持页面布局
                newItems.append(.empty(token))
            }
        }
        
        // 第二步：添加新增的自由应用（不在任何文件夹中）
        let existingAppPaths = Set(newItems.compactMap { item in
            if case let .app(app) = item { return app.url.path } else { return nil }
        })

        var newFreeApps = self.apps.filter { app in
            !appsInFolders.contains(app) && !existingAppPaths.contains(app.url.path)
        }

        if !newFreeApps.isEmpty {
            // 先优先插入到“当前页面”的末尾（在 empty 之前）
            insertAppsAtEndOfCurrentPageBeforeEmpties(items: &newItems, apps: &newFreeApps)

            // 若仍有剩余，再回退到原有策略：优先填充“最后一页”的 empty，然后必要时扩展新页
            if !newFreeApps.isEmpty {
                let itemsPerPage = self.itemsPerPage
                let currentPages = (newItems.count + itemsPerPage - 1) / itemsPerPage
                let lastPageStart = currentPages > 0 ? (currentPages - 1) * itemsPerPage : 0
                let lastPageRange = lastPageStart..<lastPageStart+itemsPerPage
                // 收集最后一页的empty槽索引
                var lastPageEmptyIndices: [Int] = []
                for idx in lastPageRange {
                    if idx < newItems.count, case .empty = newItems[idx] {
                        lastPageEmptyIndices.append(idx)
                    }
                }
                var appsToInsert = ArraySlice(newFreeApps)
                // 先填充已有empty
                for idx in lastPageEmptyIndices.prefix(appsToInsert.count) {
                    if let app = appsToInsert.first {
                        newItems[idx] = .app(app)
                        appsToInsert = appsToInsert.dropFirst()
                    }
                }
                // 如果还有剩余app，先补空到完整页，再append到新页
                if !appsToInsert.isEmpty {
                    let lastPageCount = newItems.count - lastPageStart
                    if lastPageCount < itemsPerPage {
                        for _ in 0..<(itemsPerPage - lastPageCount) {
                            newItems.append(.empty(UUID().uuidString))
                        }
                    }
                    for app in appsToInsert {
                        newItems.append(.app(app))
                    }
                }
            }
        }
        
        self.items = newItems

    }
    
    /// 从扫描结果重新构建（没有持久化数据时）
    private func rebuildFromScannedApps(newApps: [AppInfo]) {
        
        // 创建新的应用列表
        var newItems: [LaunchpadItem] = []
        
        // 添加所有自由应用（不在文件夹中的），保持现有顺序
        let appsInFolders = Set(self.folders.flatMap { $0.apps })
        let freeApps = self.apps.filter { !appsInFolders.contains($0) }
        
        // 保持现有顺序，不重新排序
        for app in freeApps {
            newItems.append(.app(app))
        }
        
        // 添加文件夹
        for folder in self.folders {
            newItems.append(.folder(folder))
        }
        
        // 添加新增应用
        for app in newApps {
            if !appsInFolders.contains(app) && !freeApps.contains(app) {
                newItems.append(.app(app))
            }
        }
        
        // 优先把新增应用放到“当前页面”的末尾（在 empty 之前）
        if !newApps.isEmpty {
            var appsToPlace = newApps
            insertAppsAtEndOfCurrentPageBeforeEmpties(items: &newItems, apps: &appsToPlace)

            // 若仍有剩余，回退到原有策略：填充最后一页 empty，必要时扩展新页
            if !appsToPlace.isEmpty {
                let itemsPerPage = self.itemsPerPage
                let currentPages = (newItems.count + itemsPerPage - 1) / itemsPerPage
                let lastPageStart = currentPages > 0 ? (currentPages - 1) * itemsPerPage : 0
                let lastPageRange = lastPageStart..<lastPageStart+itemsPerPage

                // 收集最后一页的 empty 槽位
                var lastPageEmptyIndices: [Int] = []
                for idx in lastPageRange {
                    if idx < newItems.count, case .empty = newItems[idx] {
                        lastPageEmptyIndices.append(idx)
                    }
                }

                var remains = ArraySlice(appsToPlace)
                for idx in lastPageEmptyIndices.prefix(remains.count) {
                    if let app = remains.first {
                        newItems[idx] = .app(app)
                        remains = remains.dropFirst()
                    }
                }

                if !remains.isEmpty {
                    let lastPageCount = newItems.count - lastPageStart
                    if lastPageCount < itemsPerPage {
                        for _ in 0..<(itemsPerPage - lastPageCount) {
                            newItems.append(.empty(UUID().uuidString))
                        }
                    }
                    for app in remains {
                        newItems.append(.app(app))
                    }
                }
            }
        }

        // 最后确保最后一页是完整的（如果不是最后一页，填充空槽位）
        let itemsPerPage = self.itemsPerPage
        let currentPages = (newItems.count + itemsPerPage - 1) / itemsPerPage
        let lastPageStart = currentPages > 0 ? (currentPages - 1) * itemsPerPage : 0
        let lastPageEnd = newItems.count

        if lastPageEnd < lastPageStart + itemsPerPage {
            let remainingSlots = itemsPerPage - (lastPageEnd - lastPageStart)
            for _ in 0..<remainingSlots {
                newItems.append(.empty(UUID().uuidString))
            }
        }

        self.items = newItems
    }
    
    /// 只加载文件夹信息，不重建项目顺序
    private func loadFoldersFromPersistedData() {
        guard let modelContext = self.modelContext else { return }
        
        do {
            // 尝试从新的"页-槽位"模型读取文件夹信息
            let saved = try modelContext.fetch(FetchDescriptor<PageEntryData>(
                sortBy: [SortDescriptor(\.pageIndex, order: .forward), SortDescriptor(\.position, order: .forward)]
            ))
            
            if !saved.isEmpty {
                // 构建文件夹
                var folderMap: [String: FolderInfo] = [:]
                var foldersInOrder: [FolderInfo] = []
                
                for row in saved where row.kind == "folder" {
                    guard let fid = row.folderId else { continue }
                    if folderMap[fid] != nil { continue }
                    
                    let folderApps: [AppInfo] = row.appPaths.compactMap { path in
                        if let existing = apps.first(where: { $0.url.path == path }) {
                            return existing
                        }
                        let url = URL(fileURLWithPath: path)
                        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                        return self.appInfo(from: url)
                    }
                    
                    let folder = FolderInfo(id: fid, name: row.folderName ?? NSLocalizedString("Untitled", comment: "Untitled"), apps: folderApps, createdAt: row.createdAt)
                    folderMap[fid] = folder
                    foldersInOrder.append(folder)
                }
                
                self.folders = foldersInOrder
            }
        } catch {
        }
    }

    deinit {
        stopAutoRescan()
    }

    // MARK: - FSEvents wiring
    func startAutoRescan() {
        guard fsEventStream == nil else { return }

        let pathsToWatch: [String] = effectiveApplicationSearchPaths()
        if pathsToWatch.isEmpty { return }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { (streamRef, clientInfo, numEvents, eventPaths, eventFlags, eventIds) in
            guard let info = clientInfo else { return }
            
            do {
                let appStore = Unmanaged<AppStore>.fromOpaque(info).takeUnretainedValue()

                guard numEvents > 0 else {
                    appStore.handleFSEvents(paths: [], flagsPointer: eventFlags, count: 0)
                    return
                }
                
                // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArray of CFString
                let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                let nsArray = cfArray as NSArray
                guard let pathsArray = nsArray as? [String] else { return }

                appStore.handleFSEvents(paths: pathsArray, flagsPointer: eventFlags, count: numEvents)
            }
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        let latency: CFTimeInterval = 0.0

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            pathsToWatch as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }

        fsEventStream = stream
        FSEventStreamSetDispatchQueue(stream, fsEventsQueue)
        FSEventStreamStart(stream)
    }

    func stopAutoRescan() {
        guard let stream = fsEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        fsEventStream = nil
    }

    func restartAutoRescan() {
        stopAutoRescan()
        startAutoRescan()
    }

    private func handleFSEvents(paths: [String], flagsPointer: UnsafePointer<FSEventStreamEventFlags>?, count: Int) {
        let maxCount = min(paths.count, count)
        var localForceFull = false
        
        for i in 0..<maxCount {
            let rawPath = paths[i]
            let flags = flagsPointer?[i] ?? 0

            let created = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)) != 0
            let removed = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved)) != 0
            let renamed = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)) != 0
            let modified = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)) != 0
            let isDir = (flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)) != 0

            if isDir && (created || removed || renamed), effectiveApplicationSearchPaths().contains(where: { rawPath.hasPrefix($0) }) {
                localForceFull = true
                break
            }

            guard let appBundlePath = self.canonicalAppBundlePath(for: rawPath) else { continue }
            if created || removed || renamed || modified {
                pendingChangedAppPaths.insert(appBundlePath)
            }
        }

        if localForceFull { pendingForceFullScan = true }
        scheduleRescan()
    }

    private func scheduleRescan() {
        // 轻微防抖，避免频繁FSEvents触发造成主线程压力
        rescanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performImmediateRefresh() }
        rescanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func performImmediateRefresh() {
        if pendingForceFullScan || pendingChangedAppPaths.count > fullRescanThreshold {
            pendingForceFullScan = false
            pendingChangedAppPaths.removeAll()
            scanApplications()
            return
        }
        
        let changed = pendingChangedAppPaths
        pendingChangedAppPaths.removeAll()
        
        if !changed.isEmpty {
            applyIncrementalChanges(for: changed)
        }
    }


    private func applyIncrementalChanges(for changedPaths: Set<String>) {
        guard !changedPaths.isEmpty else { return }
        
        // 将磁盘与图标解析放到后台，主线程仅应用结果，减少卡顿
        let snapshotApps = self.apps
        refreshQueue.async { [weak self] in
            guard let self else { return }
            
            enum PendingChange {
                case insert(AppInfo)
                case update(AppInfo)
                case remove(String) // path
            }
            var changes: [PendingChange] = []
            var pathToIndex: [String: Int] = [:]
            for (idx, app) in snapshotApps.enumerated() { pathToIndex[app.url.path] = idx }
            
            for path in changedPaths {
                let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let exists = FileManager.default.fileExists(atPath: url.path)
                let valid = exists && self.isValidApp(at: url) && !self.isInsideAnotherApp(url)
                if valid {
                    let info = self.appInfo(from: url)
                    if pathToIndex[url.path] != nil {
                        changes.append(.update(info))
                    } else {
                        changes.append(.insert(info))
                    }
                } else {
                    changes.append(.remove(url.path))
                }
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                
                // 应用删除
                if changes.contains(where: { if case .remove = $0 { return true } else { return false } }) {
                    var indicesToRemove: [Int] = []
                    var map: [String: Int] = [:]
                    for (idx, app) in self.apps.enumerated() { map[app.url.path] = idx }
                    for change in changes {
                        if case .remove(let path) = change, let idx = map[path] {
                            indicesToRemove.append(idx)
                        }
                    }
                    for idx in indicesToRemove.sorted(by: >) {
                        let removed = self.apps.remove(at: idx)
                        for fIdx in self.folders.indices { self.folders[fIdx].apps.removeAll { $0 == removed } }
                        if !self.items.isEmpty {
                            for i in 0..<self.items.count {
                                if case let .app(a) = self.items[i], a == removed { self.items[i] = .empty(UUID().uuidString) }
                            }
                        }
                    }
                    self.compactItemsWithinPages()
                    self.rebuildItems()
                }
                
                // 应用更新
                let updates: [AppInfo] = changes.compactMap { if case .update(let info) = $0 { return info } else { return nil } }
                if !updates.isEmpty {
                    var map: [String: Int] = [:]
                    for (idx, app) in self.apps.enumerated() { map[app.url.path] = idx }
                    for info in updates {
                        if let idx = map[info.url.path], self.apps.indices.contains(idx) { self.apps[idx] = info }
                        for fIdx in self.folders.indices {
                            for aIdx in self.folders[fIdx].apps.indices where self.folders[fIdx].apps[aIdx].url.path == info.url.path {
                                self.folders[fIdx].apps[aIdx] = info
                            }
                        }
                        for iIdx in self.items.indices {
                            if case .app(let a) = self.items[iIdx], a.url.path == info.url.path { self.items[iIdx] = .app(info) }
                        }
                    }
                    self.rebuildItems()
                }
                
                // 新增应用
                let inserts: [AppInfo] = changes.compactMap { if case .insert(let info) = $0 { return info } else { return nil } }
                if !inserts.isEmpty {
                    self.apps.append(contentsOf: inserts)
                    self.apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    self.rebuildItems()
                }
                
                // 刷新与持久化
                self.triggerFolderUpdate()
                self.triggerGridRefresh()
                self.saveAllOrder()
                self.pruneEmptyFolders()
                self.updateCacheAfterChanges()
            }
        }
    }

    private func canonicalAppBundlePath(for rawPath: String) -> String? {
        guard let range = rawPath.range(of: ".app") else { return nil }
        let end = rawPath.index(range.lowerBound, offsetBy: 4)
        let bundlePath = String(rawPath[..<end])
        return bundlePath
    }

    private func isInsideAnotherApp(_ url: URL) -> Bool {
        let appCount = url.pathComponents.filter { $0.hasSuffix(".app") }.count
        return appCount > 1
    }

    private func isValidApp(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) &&
        NSWorkspace.shared.isFilePackage(atPath: url.path)
    }

    private func appInfo(from url: URL) -> AppInfo {
        let name = localizedAppName(for: url)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return AppInfo(name: name, icon: icon, url: url)
    }
    
    // MARK: - 文件夹管理
    func createFolder(with apps: [AppInfo], name: String = NSLocalizedString("Untitled", comment: "Untitled")) -> FolderInfo {
        return createFolder(with: apps, name: name, insertAt: nil)
    }

    func createFolder(with apps: [AppInfo], name: String = NSLocalizedString("Untitled", comment: "Untitled"), insertAt insertIndex: Int?) -> FolderInfo {
        let folder = FolderInfo(name: name, apps: apps)
        folders.append(folder)

        // 从应用列表中移除已添加到文件夹的应用（顶层 apps）
        for app in apps {
            if let index = self.apps.firstIndex(of: app) {
                self.apps.remove(at: index)
            }
        }

        // 在当前 items 中：将这些 app 的顶层条目替换为空槽，并在目标位置放置文件夹，保持总长度不变
        var newItems = self.items
        // 找出这些 app 的位置
        var indices: [Int] = []
        for (idx, item) in newItems.enumerated() {
            if case let .app(a) = item, apps.contains(a) { indices.append(idx) }
            if indices.count == apps.count { break }
        }
        // 将涉及的 app 槽位先置空
        for idx in indices { newItems[idx] = .empty(UUID().uuidString) }
        // 选择放置文件夹的位置：优先 insertIndex，否则用最小索引；夹紧范围并用替换而非插入
        let baseIndex = indices.min() ?? min(newItems.count - 1, max(0, insertIndex ?? (newItems.count - 1)))
        let desiredIndex = insertIndex ?? baseIndex
        let safeIndex = min(max(0, desiredIndex), max(0, newItems.count - 1))
        if newItems.isEmpty {
            newItems = [.folder(folder)]
        } else {
            newItems[safeIndex] = .folder(folder)
        }
        self.items = newItems
        // 单页内自动补位：将该页内的空槽移到页尾
        compactItemsWithinPages()

        // 触发文件夹更新，通知所有相关视图刷新图标
        DispatchQueue.main.async { [weak self] in
            self?.triggerFolderUpdate()
        }
        
        // 触发网格视图刷新，确保界面立即更新
        triggerGridRefresh()
        
        // 刷新缓存，确保搜索时能找到新创建文件夹内的应用
        refreshCacheAfterFolderOperation()

        saveAllOrder()
        return folder
    }
    
    func addAppToFolder(_ app: AppInfo, folder: FolderInfo) {
        guard let folderIndex = folders.firstIndex(of: folder) else { return }
        
        // 创建新的FolderInfo实例，确保SwiftUI能够检测到变化
        var updatedFolder = folders[folderIndex]
        updatedFolder.apps.append(app)
        folders[folderIndex] = updatedFolder
        
        // 从应用列表中移除
        if let appIndex = apps.firstIndex(of: app) {
            apps.remove(at: appIndex)
        }
        
        // 顶层将该 app 槽位置为 empty（保持页独立）
        // 替换 items 中所有与该 app 匹配的条目为 empty，避免残留重复
        var newItems = items
        var replacedAtLeastOnce = false
        for i in newItems.indices {
            if case .app(let a) = newItems[i], a == app {
                newItems[i] = .empty(UUID().uuidString)
                replacedAtLeastOnce = true
            }
        }
        items = newItems
        
        // 单页内自动补位，确保页面结构合理
        compactItemsWithinPages()
        
        // 确保 items 中对应的文件夹条目也更新为最新内容，便于搜索立即可见
        for idx in items.indices {
            if case .folder(let f) = items[idx], f.id == updatedFolder.id {
                items[idx] = .folder(updatedFolder)
            }
        }
        
        // 立即触发文件夹更新，通知所有相关视图刷新图标和名称
        triggerFolderUpdate()
        
        // 触发网格视图刷新，确保界面立即更新
        triggerGridRefresh()
        
        // 刷新缓存，确保搜索时能找到新添加的应用
        refreshCacheAfterFolderOperation()
        
        saveAllOrder()
    }
    
    func removeAppFromFolder(_ app: AppInfo, folder: FolderInfo) {
        guard let folderIndex = folders.firstIndex(of: folder) else { return }
        
        // 创建新的FolderInfo实例，确保SwiftUI能够检测到变化
        var updatedFolder = folders[folderIndex]
        updatedFolder.apps.removeAll { $0 == app }
        
        // 如果文件夹空了，删除文件夹
        if updatedFolder.apps.isEmpty {
            folders.remove(at: folderIndex)
        } else {
            // 更新文件夹
            folders[folderIndex] = updatedFolder
        }
        
        // 同步更新 items 中的该文件夹条目，避免界面继续引用旧的文件夹内容
        for idx in items.indices {
            if case .folder(let f) = items[idx], f.id == folder.id {
                if updatedFolder.apps.isEmpty {
                    // 文件夹已空并被删除，则将该位置标记为空槽，等待后续补位
                    items[idx] = .empty(UUID().uuidString)
                } else {
                    items[idx] = .folder(updatedFolder)
                }
            }
        }
        
        // Detect if we're in the middle of a drag handoff out of the folder
        let currentEventType = NSApp.currentEvent?.type
        let isDraggingNow = (currentEventType == .leftMouseDragged)
        let isHandoffDrag = isDraggingNow || handoffDraggingApp != nil || handoffDragScreenLocation != nil
        
        // 将应用重新添加到应用列表
        apps.append(app)
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        if isHandoffDrag {
            // 处于接力拖拽：将应用临时放回到网格中的一个空槽位，保证可见性
            handoffDraggingApp = app
            if let emptyIndex = items.firstIndex(where: { if case .empty = $0 { return true } else { return false } }) {
                items[emptyIndex] = .app(app)
            } else {
                // 没有空槽位时，追加到末尾一页
                items.append(.app(app))
            }
            // 不进行页面压缩，避免拖拽中槽位跳动
        } else {
            // 非拖拽场景：保持原有回填逻辑
            if let emptyIndex = items.firstIndex(where: { if case .empty = $0 { return true } else { return false } }) {
                items[emptyIndex] = .app(app)
            } else {
                items.append(.app(app))
            }
            // 直接进行页面内压缩，保持页面完整性
            compactItemsWithinPages()
        }
        
        // 立即触发文件夹更新，通知所有相关视图刷新图标和名称
        triggerFolderUpdate()
        
        // 触发网格视图刷新，确保界面立即更新
        triggerGridRefresh()
        
        // 刷新缓存，确保搜索时能找到从文件夹移除的应用（在重建之后刷新）
        refreshCacheAfterFolderOperation()
        
        saveAllOrder()
    }
    
    func renameFolder(_ folder: FolderInfo, newName: String) {
        guard let index = folders.firstIndex(of: folder) else { return }
        
        
        // 创建新的FolderInfo实例，确保SwiftUI能够检测到变化
        var updatedFolder = folders[index]
        updatedFolder.name = newName
        folders[index] = updatedFolder
        
        // 同步更新 items 中的该文件夹条目，避免主网格继续显示旧名称
        for idx in items.indices {
            if case .folder(let f) = items[idx], f.id == updatedFolder.id {
                items[idx] = .folder(updatedFolder)
            }
        }
        
        // End any ongoing name editing once rename completes
        isFolderNameEditing = false
        
        // 立即触发文件夹更新，通知所有相关视图刷新
        triggerFolderUpdate()
        
        // 触发网格视图刷新，确保界面立即更新
        triggerGridRefresh()
        
        // 刷新缓存，确保搜索功能正常工作
        refreshCacheAfterFolderOperation()
        
        rebuildItems()
        saveAllOrder()
    }
    
    // 一键重置布局：完全重新扫描应用，删除所有文件夹、排序和empty填充
    func resetLayout() {
        // 关闭打开的文件夹
        openFolder = nil
        
        // 清空所有文件夹和排序数据
        folders.removeAll()
        
        // 清除所有持久化的排序数据
        clearAllPersistedData()
        
        // 清除缓存
        cacheManager.clearAllCaches()
        
        // 重置扫描标记，强制重新扫描
        hasPerformedInitialScan = false
        
        // 清空当前项目列表
        items.removeAll()
        
        // 重新扫描应用，不加载持久化数据
        scanApplications(loadPersistedOrder: false)
        
        // 重置到第一页
        currentPage = 0
        
        // 触发文件夹更新，通知所有相关视图刷新
        triggerFolderUpdate()
        
        // 触发网格视图刷新，确保界面立即更新
        triggerGridRefresh()
        
        // 扫描完成后刷新缓存
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshCacheAfterFolderOperation()
        }
    }
    
    /// 单页内自动补位：将每页的 .empty 槽位移动到该页尾部，保持非空项的相对顺序
    func compactItemsWithinPages() {
        guard !items.isEmpty else { return }
        let itemsPerPage = self.itemsPerPage // 使用计算属性
        var result: [LaunchpadItem] = []
        result.reserveCapacity(items.count)
        var index = 0
        while index < items.count {
            let end = min(index + itemsPerPage, items.count)
            let pageSlice = Array(items[index..<end])
            let nonEmpty = pageSlice.filter { if case .empty = $0 { return false } else { return true } }
            let emptyCount = pageSlice.count - nonEmpty.count
            
            // 先添加非空项目，保持原有顺序
            result.append(contentsOf: nonEmpty)
            
            // 再添加empty项目到页面末尾
            if emptyCount > 0 {
                var empties: [LaunchpadItem] = []
                empties.reserveCapacity(emptyCount)
                for _ in 0..<emptyCount { empties.append(.empty(UUID().uuidString)) }
                result.append(contentsOf: empties)
            }
            
            index = end
        }
        items = result
    }

    // MARK: - 跨页拖拽：级联插入（满页则将最后一个推入下一页）
    func moveItemAcrossPagesWithCascade(item: LaunchpadItem, to targetIndex: Int) {
        guard items.indices.contains(targetIndex) || targetIndex == items.count else {
            return
        }
        guard let source = items.firstIndex(of: item) else { return }
        var result = items
        // 源位置置空，保持长度
        result[source] = .empty(UUID().uuidString)
        // 执行级联插入
        result = cascadeInsert(into: result, item: item, at: targetIndex)
        items = result
        
        // 每次拖拽结束后都进行压缩，确保每页的empty项目移动到页面末尾
        let targetPage = targetIndex / itemsPerPage
        let currentPages = (items.count + itemsPerPage - 1) / itemsPerPage
        
        if targetPage == currentPages - 1 {
            // 拖拽到新页面，延迟压缩以确保应用位置稳定
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.compactItemsWithinPages()
                self.triggerGridRefresh()
            }
        } else {
            // 拖拽到现有页面，立即压缩
            compactItemsWithinPages()
        }
        
        // 触发网格视图刷新，确保界面立即更新
        triggerGridRefresh()
        
        saveAllOrder()
    }

    private func cascadeInsert(into array: [LaunchpadItem], item: LaunchpadItem, at targetIndex: Int) -> [LaunchpadItem] {
        var result = array
        let p = self.itemsPerPage // 使用计算属性

        // 确保长度填充为整页，便于处理
        if result.count % p != 0 {
            let remain = p - (result.count % p)
            for _ in 0..<remain { result.append(.empty(UUID().uuidString)) }
        }

        var currentPage = max(0, targetIndex / p)
        var localIndex = max(0, min(targetIndex - currentPage * p, p - 1))
        var carry: LaunchpadItem? = item

        while let moving = carry {
            let pageStart = currentPage * p
            let pageEnd = pageStart + p
            if result.count < pageEnd {
                let need = pageEnd - result.count
                for _ in 0..<need { result.append(.empty(UUID().uuidString)) }
            }
            var slice = Array(result[pageStart..<pageEnd])
            
            // 确保插入位置在有效范围内
            let safeLocalIndex = max(0, min(localIndex, slice.count))
            slice.insert(moving, at: safeLocalIndex)
            
            var spilled: LaunchpadItem? = nil
            if slice.count > p {
                spilled = slice.removeLast()
            }
            result.replaceSubrange(pageStart..<pageEnd, with: slice)
            if let s = spilled, case .empty = s {
                // 溢出为空：结束
                carry = nil
            } else if let s = spilled {
                // 溢出非空：推到下一页页首
                carry = s
                currentPage += 1
                localIndex = 0
                // 若到最后超过长度，填充下一页
                let nextEnd = (currentPage + 1) * p
                if result.count < nextEnd {
                    let need = nextEnd - result.count
                    for _ in 0..<need { result.append(.empty(UUID().uuidString)) }
                }
            } else {
                carry = nil
            }
        }
        return result
    }
    
    // 修改的 rebuildItems 函数
    func rebuildItems() {
        // 增加防抖和优化检查
        let currentItemsCount = items.count
        let appsInFolders: Set<AppInfo> = Set(folders.flatMap { $0.apps })
        let folderById: [String: FolderInfo] = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })

        var newItems: [LaunchpadItem] = []
        newItems.reserveCapacity(currentItemsCount + 10) // 预分配容量
        var seenAppPaths = Set<String>()
        var seenFolderIds = Set<String>()
        seenAppPaths.reserveCapacity(apps.count)
        seenFolderIds.reserveCapacity(folders.count)

        for item in items {
            switch item {
            case .folder(let folder):
                if let updated = folderById[folder.id] {
                    newItems.append(.folder(updated))
                    seenFolderIds.insert(updated.id)
                }
                // 若该文件夹已被删除，则跳过（不再保留）
            case .app(let app):
                // 如果 app 已进入某个文件夹，或已从磁盘删除，则从顶层移除；否则保留其原有位置
                let existsInApps = self.apps.contains(where: { $0.url.path == app.url.path })
                if existsInApps && !appsInFolders.contains(app) {
                    newItems.append(.app(app))
                    seenAppPaths.insert(app.url.path)
                } else {
                    // 不存在（已删除）或已进入文件夹：保持空槽位，固定页边界
                    newItems.append(.empty(UUID().uuidString))
                }
            case .empty(let token):
                // 保留 empty 作为占位，维持每页独立
                newItems.append(.empty(token))
            }
        }

        // 追加遗漏的自由应用（未在顶层出现，但也不在任何文件夹中）
        let missingFreeApps = apps.filter { !appsInFolders.contains($0) && !seenAppPaths.contains($0.url.path) }
        newItems.append(contentsOf: missingFreeApps.map { .app($0) })

        // 注意：不要自动把缺失的文件夹追加到末尾，
        // 以免在加载持久化顺序后，因增量更新触发重建时把文件夹推到最后一页。

        // 只有在实际变化时才更新items
        if newItems.count != items.count || !newItems.elementsEqual(items, by: { $0.id == $1.id }) {
            items = newItems
            // 新增/替换 empty 后，将本页 empty 移到页尾
            compactItemsWithinPages()
        }
    }
    
    // MARK: - 持久化：每页独立排序（新）+ 兼容旧版
    func loadAllOrder() {
        guard let modelContext else {
            print("LaunchNow: ModelContext is nil, cannot load persisted order")
            return
        }
        
        print("LaunchNow: Attempting to load persisted order data...")
        
        // 优先尝试从新的"页-槽位"模型读取
        if loadOrderFromPageEntries(using: modelContext) {
            print("LaunchNow: Successfully loaded order from PageEntryData")
            return
        }
        
        print("LaunchNow: PageEntryData not found, trying legacy TopItemData...")
        // 回退：旧版全局顺序模型
        loadOrderFromLegacyTopItems(using: modelContext)
        print("LaunchNow: Finished loading order from legacy data")
    }

    private func loadOrderFromPageEntries(using modelContext: ModelContext) -> Bool {
        do {
            let descriptor = FetchDescriptor<PageEntryData>(
                sortBy: [SortDescriptor(\.pageIndex, order: .forward), SortDescriptor(\.position, order: .forward)]
            )
            let saved = try modelContext.fetch(descriptor)
            guard !saved.isEmpty else { return false }

            // 构建文件夹：按首次出现顺序
            var folderMap: [String: FolderInfo] = [:]
            var foldersInOrder: [FolderInfo] = []

            // 先收集所有 folder 的 appPaths，避免重复构建
            for row in saved where row.kind == "folder" {
                guard let fid = row.folderId else { continue }
                if folderMap[fid] != nil { continue }

                let folderApps: [AppInfo] = row.appPaths.compactMap { path in
                    if let existing = apps.first(where: { $0.url.path == path }) {
                        return existing
                    }
                    let url = URL(fileURLWithPath: path)
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return self.appInfo(from: url)
                }
                let folder = FolderInfo(id: fid, name: row.folderName ?? NSLocalizedString("Untitled", comment: "Untitled"), apps: folderApps, createdAt: row.createdAt)
                folderMap[fid] = folder
                foldersInOrder.append(folder)
            }

            let folderAppPathSet: Set<String> = Set(foldersInOrder.flatMap { $0.apps.map { $0.url.path } })

            // 合成顶层 items（按页与位置的顺序；保留 empty 以维持每页独立槽位）
            var combined: [LaunchpadItem] = []
            combined.reserveCapacity(saved.count)
            for row in saved {
                switch row.kind {
                case "folder":
                    if let fid = row.folderId, let folder = folderMap[fid] {
                        combined.append(.folder(folder))
                    }
                case "app":
                    if let path = row.appPath, !folderAppPathSet.contains(path) {
                        if let existing = apps.first(where: { $0.url.path == path }) {
                            combined.append(.app(existing))
                        } else {
                            let url = URL(fileURLWithPath: path)
                            if FileManager.default.fileExists(atPath: url.path) {
                                combined.append(.app(self.appInfo(from: url)))
                            } else {
                                // 应用已缺失：保留空槽位，避免跨页回填
                                combined.append(.empty(row.slotId))
                            }
                        }
                    } else {
                        // 数据不完整：保留空槽位
                        combined.append(.empty(row.slotId))
                    }
                case "empty":
                    combined.append(.empty(row.slotId))
                default:
                    break
                }
            }

            DispatchQueue.main.async {
                self.folders = foldersInOrder
                if !combined.isEmpty {
                    self.items = combined
                    // 载入后对每页进行 empty 压缩到页尾
                    self.compactItemsWithinPages()
                    // 如果应用列表为空，从持久化数据中恢复应用列表
                    if self.apps.isEmpty {
                        let freeApps: [AppInfo] = combined.compactMap { if case let .app(a) = $0 { return a } else { return nil } }
                        self.apps = freeApps
                    }
                }
                self.hasAppliedOrderFromStore = true
            }
            return true
        } catch {
            return false
        }
    }

    private func loadOrderFromLegacyTopItems(using modelContext: ModelContext) {
        do {
            let descriptor = FetchDescriptor<TopItemData>(sortBy: [SortDescriptor(\.orderIndex, order: .forward)])
            let saved = try modelContext.fetch(descriptor)
            guard !saved.isEmpty else { return }

            var folderMap: [String: FolderInfo] = [:]
            var foldersInOrder: [FolderInfo] = []
            let folderAppPathSet: Set<String> = Set(saved.filter { $0.kind == "folder" }.flatMap { $0.appPaths })
            for row in saved where row.kind == "folder" {
                let folderApps: [AppInfo] = row.appPaths.compactMap { path in
                    if let existing = apps.first(where: { $0.url.path == path }) { return existing }
                    let url = URL(fileURLWithPath: path)
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return self.appInfo(from: url)
                }
                let folder = FolderInfo(id: row.id, name: row.folderName ?? NSLocalizedString("Untitled", comment: "Untitled"), apps: folderApps, createdAt: row.createdAt)
                folderMap[row.id] = folder
                foldersInOrder.append(folder)
            }

            var combined: [LaunchpadItem] = []
            for row in saved.sorted(by: { $0.orderIndex < $1.orderIndex }) {
                switch row.kind {
                case "folder":
                    if let folder = folderMap[row.id] {
                        combined.append(.folder(folder))
                    } else {
                        // 旧数据中指向的文件夹不存在时，保留空槽位
                        combined.append(.empty(row.id))
                    }
                case "empty":
                    combined.append(.empty(row.id))
                case "app":
                    if let path = row.appPath {
                        if folderAppPathSet.contains(path) {
                            // 已在文件夹中：保留空槽位
                            combined.append(.empty(row.id))
                        } else if let existing = apps.first(where: { $0.url.path == path }) {
                            combined.append(.app(existing))
                        } else {
                            let url = URL(fileURLWithPath: path)
                            if FileManager.default.fileExists(atPath: url.path) {
                                combined.append(.app(self.appInfo(from: url)))
                            } else {
                                // 应用缺失：保留空槽位
                                combined.append(.empty(row.id))
                            }
                        }
                    } else {
                        // 无有效路径：保留空槽位
                        combined.append(.empty(row.id))
                    }
                default:
                    // 未知类型：保留空槽位
                    combined.append(.empty(row.id))
                }
            }

            let appsInFolders = Set(foldersInOrder.flatMap { $0.apps })
            let appsInCombined: Set<AppInfo> = Set(combined.compactMap { if case let .app(a) = $0 { return a } else { return nil } })
            let missingFreeApps = apps
                .filter { !appsInFolders.contains($0) && !appsInCombined.contains($0) }
                .map { LaunchpadItem.app($0) }
            combined.append(contentsOf: missingFreeApps)

            DispatchQueue.main.async {
                self.folders = foldersInOrder
                if !combined.isEmpty {
                    self.items = combined
                    // 载入后对每页进行 empty 压缩到页尾
                    self.compactItemsWithinPages()
                    // 如果应用列表为空，从持久化数据中恢复应用列表
                    if self.apps.isEmpty {
                        let freeAppsAfterLoad: [AppInfo] = combined.compactMap { if case let .app(a) = $0 { return a } else { return nil } }
                        self.apps = freeAppsAfterLoad
                    }
                }
                self.hasAppliedOrderFromStore = true
            }
        } catch {
            // ignore
        }
    }

    func saveAllOrder() {
        guard let modelContext else {
            print("LaunchNow: ModelContext is nil, cannot save order")
            return
        }
        guard !items.isEmpty else {
            print("LaunchNow: Items list is empty, skipping save")
            return
        }

        print("LaunchNow: Saving order data for \(items.count) items...")
        
        // 写入新模型：按页-槽位
        do {
            let existing = try modelContext.fetch(FetchDescriptor<PageEntryData>())
            print("LaunchNow: Found \(existing.count) existing entries, clearing...")
            for row in existing { modelContext.delete(row) }

            // 构建 folders 查找表
            let folderById: [String: FolderInfo] = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
            let itemsPerPage = self.itemsPerPage // 使用计算属性

            for (idx, item) in items.enumerated() {
                let pageIndex = idx / itemsPerPage
                let position = idx % itemsPerPage
                let slotId = "page-\(pageIndex)-pos-\(position)"
                switch item {
                case .folder(let folder):
                    let authoritativeFolder = folderById[folder.id] ?? folder
                    let row = PageEntryData(
                        slotId: slotId,
                        pageIndex: pageIndex,
                        position: position,
                        kind: "folder",
                        folderId: authoritativeFolder.id,
                        folderName: authoritativeFolder.name,
                        appPaths: authoritativeFolder.apps.map { $0.url.path }
                    )
                    modelContext.insert(row)
                case .app(let app):
                    let row = PageEntryData(
                        slotId: slotId,
                        pageIndex: pageIndex,
                        position: position,
                        kind: "app",
                        appPath: app.url.path
                    )
                    modelContext.insert(row)
                case .empty:
                    let row = PageEntryData(
                        slotId: slotId,
                        pageIndex: pageIndex,
                        position: position,
                        kind: "empty"
                    )
                    modelContext.insert(row)
                }
            }
            try modelContext.save()
            print("LaunchNow: Successfully saved order data")
            
            // 清理旧版表，避免占用空间（忽略错误）
            do {
                let legacy = try modelContext.fetch(FetchDescriptor<TopItemData>())
                for row in legacy { modelContext.delete(row) }
                try? modelContext.save()
            } catch { }
        } catch {
            print("LaunchNow: Error saving order data: \(error)")
        }
    }

    // 触发文件夹更新，通知所有相关视图刷新图标
    private func triggerFolderUpdate() {
        folderUpdateTrigger = UUID()
    }
    
    // 触发网格视图刷新，用于拖拽操作后的界面更新
    func triggerGridRefresh() {
        gridRefreshTrigger = UUID()
    }
    
    
    // 清除所有持久化的排序和文件夹数据
    private func clearAllPersistedData() {
        guard let modelContext else { return }
        
        do {
            // 清除新的页-槽位数据
            let pageEntries = try modelContext.fetch(FetchDescriptor<PageEntryData>())
            for entry in pageEntries {
                modelContext.delete(entry)
            }
            
            // 清除旧版的全局顺序数据
            let legacyEntries = try modelContext.fetch(FetchDescriptor<TopItemData>())
            for entry in legacyEntries {
                modelContext.delete(entry)
            }
            
            // 保存更改
            try modelContext.save()
        } catch {
            // 忽略错误，确保重置流程继续进行
        }
    }

    // MARK: - 拖拽时自动创建新页
    private var pendingNewPage: (pageIndex: Int, itemCount: Int)? = nil
    
    func createNewPageForDrag() -> Bool {
        let itemsPerPage = self.itemsPerPage
        let currentPages = (items.count + itemsPerPage - 1) / itemsPerPage
        let newPageIndex = currentPages
        
        // 为新页添加empty占位符
        for _ in 0..<itemsPerPage {
            items.append(.empty(UUID().uuidString))
        }
        
        // 记录待处理的新页信息
        pendingNewPage = (pageIndex: newPageIndex, itemCount: itemsPerPage)
        
        // 触发网格视图刷新
        triggerGridRefresh()
        
        return true
    }
    
    func cleanupUnusedNewPage() {
        guard let pending = pendingNewPage else { return }
        
        // 检查新页是否被使用（是否有非empty项目）
        let pageStart = pending.pageIndex * pending.itemCount
        let pageEnd = min(pageStart + pending.itemCount, items.count)
        
        if pageStart < items.count {
            let pageSlice = Array(items[pageStart..<pageEnd])
            let hasNonEmptyItems = pageSlice.contains { item in
                if case .empty = item { return false } else { return true }
            }
            
            if !hasNonEmptyItems {
                // 新页没有被使用，删除它
                items.removeSubrange(pageStart..<pageEnd)
                
                // 触发网格视图刷新
                triggerGridRefresh()
            }
        }
        
        // 清除待处理信息
        pendingNewPage = nil
    }

    // MARK: - 自动删除空白页面
    /// 自动删除空白页面：删除全部都是empty填充的页面
    func removeEmptyPages() {
        guard !items.isEmpty else { return }
        let itemsPerPage = self.itemsPerPage
        
        var newItems: [LaunchpadItem] = []
        var index = 0
        
        while index < items.count {
            let end = min(index + itemsPerPage, items.count)
            let pageSlice = Array(items[index..<end])
            
            // 检查当前页是否全部都是empty
            let isEmptyPage = pageSlice.allSatisfy { item in
                if case .empty = item { return true } else { return false }
            }
            
            // 如果不是空白页面，保留该页内容
            if !isEmptyPage {
                newItems.append(contentsOf: pageSlice)
            }
            // 如果是空白页面，跳过不添加
            
            index = end
        }
        
        // 只有在实际删除了空白页面时才更新items
        if newItems.count != items.count {
            items = newItems
            
            // 删除空白页面后，确保当前页索引在有效范围内
            let maxPageIndex = max(0, (items.count - 1) / itemsPerPage)
            if currentPage > maxPageIndex {
                currentPage = maxPageIndex
            }
            
            // 触发网格视图刷新
            triggerGridRefresh()
        }
    }
    
    /// 清理空文件夹：移除没有任何应用的文件夹，并同步更新 items
    func pruneEmptyFolders() {
        // 在拖拽接力过程中避免改动布局，防止外部网格位置异常
        let currentEventType = NSApp.currentEvent?.type
        let isDraggingNow = (currentEventType == .leftMouseDragged)
        let isHandoffDrag = isDraggingNow || handoffDraggingApp != nil || handoffDragScreenLocation != nil
        if isHandoffDrag { return }

        // 收集空文件夹ID
        let emptyFolderIds: Set<String> = Set(folders.filter { $0.apps.isEmpty }.map { $0.id })
        guard !emptyFolderIds.isEmpty else { return }

        // 从文件夹列表中移除空文件夹
        folders.removeAll { emptyFolderIds.contains($0.id) }

        // 将 items 中引用这些空文件夹的位置替换为 empty 槽位
        if !items.isEmpty {
            for idx in items.indices {
                if case .folder(let f) = items[idx], emptyFolderIds.contains(f.id) {
                    items[idx] = .empty(UUID().uuidString)
                }
            }
        }

        // 页面内压缩，将 empty 槽位移动到每页末尾
        compactItemsWithinPages()

        // 触发界面刷新并保存
        triggerFolderUpdate()
        triggerGridRefresh()
        saveAllOrder()
    }
    
    // MARK: - 导出应用排序功能
    /// 导出应用排序为JSON格式
    func exportAppOrderAsJSON() -> String? {
        let exportData = buildExportData()
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: exportData, options: [.prettyPrinted, .sortedKeys])
            return String(data: jsonData, encoding: .utf8)
        } catch {
            return nil
        }
    }
    
    /// 构建导出数据
    private func buildExportData() -> [String: Any] {
        var pages: [[String: Any]] = []
        let itemsPerPage = self.itemsPerPage
        
        for (index, item) in items.enumerated() {
            let pageIndex = index / itemsPerPage
            let position = index % itemsPerPage
            
            var itemData: [String: Any] = [
                "pageIndex": pageIndex,
                "position": position,
                "kind": itemKind(for: item),
                "name": item.name,
                "path": itemPath(for: item),
                "folderApps": []
            ]
            
            // 如果是文件夹，添加文件夹内的应用信息
            if case let .folder(folder) = item {
                itemData["folderApps"] = folder.apps.map { $0.name }
                itemData["folderAppPaths"] = folder.apps.map { $0.url.path }
            }
            
            pages.append(itemData)
        }
        
        return [
            "exportDate": ISO8601DateFormatter().string(from: Date()),
            "totalPages": (items.count + itemsPerPage - 1) / itemsPerPage,
            "totalItems": items.count,
            "fullscreenMode": isFullscreenMode,
            "pages": pages
        ]
    }
    
    /// 获取项目类型描述
    private func itemKind(for item: LaunchpadItem) -> String {
        switch item {
        case .app:
            return "应用"
        case .folder:
            return "文件夹"
        case .empty:
            return "空槽位"
        }
    }
    
    /// 获取项目路径
    private func itemPath(for item: LaunchpadItem) -> String {
        switch item {
        case let .app(app):
            return app.url.path
        case let .folder(folder):
            return "文件夹: \(folder.name)"
        case .empty:
            return "空槽位"
        }
    }
    
    /// 使用系统文件保存对话框保存导出文件
    func saveExportFileWithDialog(content: String, filename: String, fileExtension: String, fileType: String) -> Bool {
        let savePanel = NSSavePanel()
        savePanel.title = "保存导出文件"
        savePanel.nameFieldStringValue = filename
        savePanel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        
        // 设置默认保存位置为桌面
        if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            savePanel.directoryURL = desktopURL
        }
        
        let response = savePanel.runModal()
        if response == .OK, let url = savePanel.url {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
        return false
    }
    
    // MARK: - 缓存管理
    
    /// 扫描完成后生成缓存
    private func generateCacheAfterScan() {
        
        // 检查缓存是否有效
        if !cacheManager.isCacheValid {
            // 生成新的缓存
            cacheManager.generateCache(from: apps, items: items)
        } else {
            // 缓存有效，但可以预加载图标
            let appPaths = apps.map { $0.url.path }
            cacheManager.preloadIcons(for: appPaths)
        }
    }
    
    /// 手动刷新（模拟全新启动的完整流程）
    func refresh() {
        // 清除缓存，确保图标与搜索索引重新生成
        cacheManager.clearAllCaches()

        // 重置界面与状态，使之接近"首次启动"
        openFolder = nil
        currentPage = 0
        if !searchText.isEmpty { searchText = "" }

        // 不要重置 hasAppliedOrderFromStore，保持布局数据
        hasPerformedInitialScan = true

        // 执行与首次启动相同的扫描路径（保持现有顺序，新增在末尾）
        scanApplicationsWithOrderPreservation()

        // 扫描完成后生成缓存
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.generateCacheAfterScan()
        }

        // 强制界面刷新
        triggerFolderUpdate()
        triggerGridRefresh()
        pruneEmptyFolders()
        removeEmptyPages()
    }
    
    /// 清除缓存
    func clearCache() {
        cacheManager.clearAllCaches()
    }
    
    /// 获取缓存统计信息
    var cacheStatistics: CacheStatistics {
        return cacheManager.cacheStatistics
    }
    
    /// 增量更新后更新缓存
    private func updateCacheAfterChanges() {
        // 检查缓存是否需要更新
        if !cacheManager.isCacheValid {
            // 缓存无效，重新生成
            cacheManager.generateCache(from: apps, items: items)
        } else {
            // 缓存有效，只更新变化的部分
            let changedAppPaths = apps.map { $0.url.path }
            cacheManager.preloadIcons(for: changedAppPaths)
        }
    }
    
    /// 文件夹操作后刷新缓存，确保搜索功能正常工作
    private func refreshCacheAfterFolderOperation() {
        // 直接刷新缓存，确保包含所有应用（包括文件夹内的应用）
        cacheManager.refreshCache(from: apps, items: items)
        
        // 清空搜索文本，确保搜索状态重置
        // 这样可以避免搜索时显示过时的结果
        if !searchText.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.searchText = ""
            }
        }
    }
    
    // MARK: - 导入应用排序功能
    /// 从JSON数据导入应用排序
    func importAppOrderFromJSON(_ jsonData: Data) -> Bool {
        do {
            let importData = try JSONSerialization.jsonObject(with: jsonData, options: [])
            return processImportedData(importData)
        } catch {
            return false
        }
    }
    
    /// 处理导入的数据并重建应用布局
    private func processImportedData(_ importData: Any) -> Bool {
        guard let data = importData as? [String: Any],
              let pagesData = data["pages"] as? [[String: Any]] else {
            return false
        }
        
        // 构建应用路径到应用对象的映射
        let appPathMap = Dictionary(uniqueKeysWithValues: apps.map { ($0.url.path, $0) })
        
        // 重建items数组
        var newItems: [LaunchpadItem] = []
        var importedFolders: [FolderInfo] = []
        
        // 处理每一页的数据
        for pageData in pagesData {
            guard let kind = pageData["kind"] as? String,
                  let name = pageData["name"] as? String else { continue }
            
            switch kind {
            case "应用":
                if let path = pageData["path"] as? String,
                   let app = appPathMap[path] {
                    newItems.append(.app(app))
                } else {
                    // 应用缺失，添加空槽位
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case "文件夹":
                if let folderApps = pageData["folderApps"] as? [String],
                   let folderAppPaths = pageData["folderAppPaths"] as? [String] {
                    // 重建文件夹 - 优先使用应用路径来匹配，确保准确性
                    let folderAppsList = folderAppPaths.compactMap { appPath in
                        // 通过应用路径匹配，这是最准确的方式
                        if let app = apps.first(where: { $0.url.path == appPath }) {
                            return app
                        }
                        // 如果路径匹配失败，尝试通过名称匹配（备用方案）
                        if let appName = folderApps.first(where: { _ in true }), // 获取对应的应用名称
                           let app = apps.first(where: { $0.name == appName }) {
                            return app
                        }
                        return nil
                    }
                    
                    if !folderAppsList.isEmpty {
                        // 尝试从现有文件夹中查找匹配的，保持ID一致
                        let existingFolder = self.folders.first { existingFolder in
                            existingFolder.name == name &&
                            existingFolder.apps.count == folderAppsList.count &&
                            existingFolder.apps.allSatisfy { app in
                                folderAppsList.contains { $0.id == app.id }
                            }
                        }
                        
                        if let existing = existingFolder {
                            // 使用现有文件夹，保持ID一致
                            importedFolders.append(existing)
                            newItems.append(.folder(existing))
                        } else {
                            // 创建新文件夹
                            let folder = FolderInfo(name: name, apps: folderAppsList)
                            importedFolders.append(folder)
                            newItems.append(.folder(folder))
                        }
                    } else {
                        // 文件夹为空，添加空槽位
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else if let folderApps = pageData["folderApps"] as? [String] {
                    // 兼容旧版本：只有应用名称，没有路径信息
                    let folderAppsList = folderApps.compactMap { appName in
                        apps.first { $0.name == appName }
                    }
                    
                    if !folderAppsList.isEmpty {
                        // 尝试从现有文件夹中查找匹配的，保持ID一致
                        let existingFolder = self.folders.first { existingFolder in
                            existingFolder.name == name &&
                            existingFolder.apps.count == folderAppsList.count &&
                            existingFolder.apps.allSatisfy { app in
                                folderAppsList.contains { $0.id == app.id }
                            }
                        }
                        
                        if let existing = existingFolder {
                            // 使用现有文件夹，保持ID一致
                            importedFolders.append(existing)
                            newItems.append(.folder(existing))
                        } else {
                            // 创建新文件夹
                            let folder = FolderInfo(name: name, apps: folderAppsList)
                            importedFolders.append(folder)
                            newItems.append(.folder(folder))
                        }
                    } else {
                        // 文件夹为空，添加空槽位
                        newItems.append(.empty(UUID().uuidString))
                    }
                } else {
                    // 文件夹数据无效，添加空槽位
                    newItems.append(.empty(UUID().uuidString))
                }
                
            case "空槽位":
                newItems.append(.empty(UUID().uuidString))
                
            default:
                // 未知类型，添加空槽位
                newItems.append(.empty(UUID().uuidString))
            }
        }
        
        // 处理多出来的应用（放到最后一页）
        let usedApps = Set(newItems.compactMap { item in
            if case let .app(app) = item { return app }
            return nil
        })
        
        let usedAppsInFolders = Set(importedFolders.flatMap { $0.apps })
        let allUsedApps = usedApps.union(usedAppsInFolders)
        
        let unusedApps = apps.filter { !allUsedApps.contains($0) }
        
        if !unusedApps.isEmpty {
            // 计算需要添加的空槽位数量
            let itemsPerPage = self.itemsPerPage
            let currentPages = (newItems.count + itemsPerPage - 1) / itemsPerPage
            let lastPageStart = currentPages * itemsPerPage
            let lastPageEnd = lastPageStart + itemsPerPage
            
            // 确保最后一页有足够的空间
            while newItems.count < lastPageEnd {
                newItems.append(.empty(UUID().uuidString))
            }
            
            // 将未使用的应用添加到最后一页
            for (index, app) in unusedApps.enumerated() {
                let insertIndex = lastPageStart + index
                if insertIndex < newItems.count {
                    newItems[insertIndex] = .app(app)
                } else {
                    newItems.append(.app(app))
                }
            }
            
            // 确保最后一页也是完整的
            let finalPageCount = newItems.count
            let finalPages = (finalPageCount + itemsPerPage - 1) / itemsPerPage
            let finalLastPageStart = (finalPages - 1) * itemsPerPage
            let finalLastPageEnd = finalLastPageStart + itemsPerPage
            
            // 如果最后一页不完整，添加空槽位
            while newItems.count < finalLastPageEnd {
                newItems.append(.empty(UUID().uuidString))
            }
        }
        
        // 验证导入的数据结构
        
        // 更新应用状态
        DispatchQueue.main.async {
            
            // 设置新的数据
            self.folders = importedFolders
            self.items = newItems
            
            
            // 强制触发界面更新
            self.triggerFolderUpdate()
            self.triggerGridRefresh()
            
            // 保存新的布局
            self.saveAllOrder()
            
            
            // 暂时不调用页面补齐，保持导入的原始顺序
            // 如果需要补齐，可以在用户手动操作后触发
        }
        
        return true
    }
    
    /// 验证导入数据的完整性
    func validateImportData(_ jsonData: Data) -> (isValid: Bool, message: String) {
        do {
            let importData = try JSONSerialization.jsonObject(with: jsonData, options: [])
            guard let data = importData as? [String: Any] else {
                return (false, "数据格式无效")
            }
            
            guard let pagesData = data["pages"] as? [[String: Any]] else {
                return (false, "缺少页面数据")
            }
            
            let totalPages = data["totalPages"] as? Int ?? 0
            let totalItems = data["totalItems"] as? Int ?? 0
            
            if pagesData.isEmpty {
                return (false, "没有找到应用数据")
            }
            
            return (true, "数据验证通过，共\(totalPages)页，\(totalItems)个项目")
        } catch {
            return (false, "JSON解析失败: \(error.localizedDescription)")
        }
    }
}

