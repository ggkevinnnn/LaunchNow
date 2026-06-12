import Foundation
import AppKit
import Combine
import os.lock

/// 应用缓存管理器 - 负责缓存应用图标、应用信息和网格布局数据以提高性能
final class AppCacheManager: ObservableObject {
    static let shared = AppCacheManager()
    
    // MARK: - 缓存存储
    private let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500
        return cache
    }()
    private var appInfoCache: [String: AppInfo] = [:]
    private var gridLayoutCache: [String: Any] = [:]
    private var cacheLock = os_unfair_lock()
    
    // MARK: - 缓存配置
    private let maxAppInfoCacheSize = 500
    
    // MARK: - 缓存状态
    @Published var isCacheValid = false
    @Published var lastCacheUpdate = Date.distantPast
    
    private init() {}
    // MARK: - 公共接口
    
    /// 生成应用缓存 - 在应用启动或扫描后调用
    func generateCache(from apps: [AppInfo], items: [LaunchpadItem]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // 清空旧缓存
            self.clearAllCaches()
            
            // 收集所有需要缓存的应用，包括文件夹内的应用
            var allApps: [AppInfo] = []
            allApps.append(contentsOf: apps)
            
            // 从items中提取文件夹内的应用
            for item in items {
                if case let .folder(folder) = item {
                    allApps.append(contentsOf: folder.apps)
                }
            }
            
            // 去重，避免重复缓存同一个应用
            var uniqueApps: [AppInfo] = []
            var seenPaths = Set<String>()
            for app in allApps {
                if !seenPaths.contains(app.url.path) {
                    seenPaths.insert(app.url.path)
                    uniqueApps.append(app)
                }
            }
            
            // 缓存应用信息
            self.cacheAppInfos(uniqueApps)
            
            // 缓存应用图标
            self.cacheAppIcons(uniqueApps)
            
            // 缓存网格布局数据
            self.cacheGridLayout(items)
            
            DispatchQueue.main.async {
                self.isCacheValid = true
                self.lastCacheUpdate = Date()
            }
        }
    }
    
    /// 获取缓存的应用图标
    func getCachedIcon(for appPath: String) -> NSImage? {
        let key = cacheKeyForIcon(appPath) as NSString
        return iconCache.object(forKey: key)
    }

    func areIconsCached(for appPaths: [String]) -> Bool {
        for path in appPaths where getCachedIcon(for: path) == nil {
            return false
        }
        return true
    }
    
    /// 获取缓存的应用信息
    func getCachedAppInfo(for appPath: String) -> AppInfo? {
        let key = cacheKeyForAppInfo(appPath)
        os_unfair_lock_lock(&cacheLock)
        defer { os_unfair_lock_unlock(&cacheLock) }
        return appInfoCache[key]
    }
    
    /// 获取缓存的网格布局数据
    func getCachedGridLayout(for layoutKey: String) -> Any? {
        let key = cacheKeyForGridLayout(layoutKey)
        os_unfair_lock_lock(&cacheLock)
        defer { os_unfair_lock_unlock(&cacheLock) }
        return gridLayoutCache[key]
    }
    
    /// 预加载应用图标到缓存
    func preloadIcons(for appPaths: [String]) {
        preloadIcons(for: appPaths, completion: nil)
    }

    /// 预加载应用图标到缓存，并在完成后回调
    func preloadIcons(for appPaths: [String], completion: (() -> Void)?) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            for path in appPaths {
                if self.getCachedIcon(for: path) == nil {
                    let icon = NSWorkspace.shared.icon(forFile: path)
                    let key = cacheKeyForIcon(path) as NSString
                    self.iconCache.setObject(icon, forKey: key)
                }
            }

            guard let completion else { return }
            DispatchQueue.main.async(execute: completion)
        }
    }
    
    /// 智能预加载：预加载当前页面和相邻页面的图标
    func smartPreloadIcons(for items: [LaunchpadItem], currentPage: Int, itemsPerPage: Int) {
        let startIndex = max(0, (currentPage - 1) * itemsPerPage)
        let endIndex = min(items.count, (currentPage + 2) * itemsPerPage)
        
        guard startIndex < endIndex else { return }
        let relevantItems = items[startIndex..<endIndex]
        let appPaths = relevantItems.compactMap { item -> String? in
            if case let .app(app) = item {
                return app.url.path
            }
            return nil
        }
        
        preloadIcons(for: appPaths)
    }
    
    /// 清除所有缓存
    func clearAllCaches() {
        os_unfair_lock_lock(&cacheLock)
        appInfoCache.removeAll()
        gridLayoutCache.removeAll()
        os_unfair_lock_unlock(&cacheLock)
        iconCache.removeAllObjects()
        
        DispatchQueue.main.async {
            self.isCacheValid = false
        }
    }
    
    /// 清除过期缓存
    func clearExpiredCache() {
        let now = Date()
        let cacheAgeThreshold: TimeInterval = 24 * 60 * 60 // 24小时
        
        if now.timeIntervalSince(lastCacheUpdate) > cacheAgeThreshold {
            clearAllCaches()
        }
    }
    
    /// 手动刷新缓存
    func refreshCache(from apps: [AppInfo], items: [LaunchpadItem]) {
        // 收集所有需要缓存的应用，包括文件夹内的应用
        var allApps: [AppInfo] = []
        allApps.append(contentsOf: apps)
        
        // 从items中提取文件夹内的应用
        for item in items {
            if case let .folder(folder) = item {
                allApps.append(contentsOf: folder.apps)
            }
        }
        
        // 去重，避免重复缓存同一个应用
        var uniqueApps: [AppInfo] = []
        var seenPaths = Set<String>()
        for app in allApps {
            if !seenPaths.contains(app.url.path) {
                seenPaths.insert(app.url.path)
                uniqueApps.append(app)
            }
        }
        
        generateCache(from: uniqueApps, items: items)
    }
    
    // MARK: - 私有方法
    
    private func cacheAppInfos(_ apps: [AppInfo]) {
        os_unfair_lock_lock(&cacheLock)
        for app in apps {
            let key = cacheKeyForAppInfo(app.url.path)
            appInfoCache[key] = app
        }
        os_unfair_lock_unlock(&cacheLock)
    }
    
    private func cacheAppIcons(_ apps: [AppInfo]) {
        for app in apps {
            let key = cacheKeyForIcon(app.url.path) as NSString
            iconCache.setObject(app.icon, forKey: key)
        }
    }
    
    private func cacheGridLayout(_ items: [LaunchpadItem]) {
        // 缓存网格布局相关的计算数据
        let layoutData = GridLayoutCacheData(
            totalItems: items.count,
            itemsPerPage: 35,
            columns: 7,
            rows: 5,
            pageCount: (items.count + 34) / 35
        )
        let pageInfo = calculatePageInfo(for: items)
        let key = cacheKeyForGridLayout("main")
        let pageKey = cacheKeyForGridLayout("pages")
        os_unfair_lock_lock(&cacheLock)
        gridLayoutCache[key] = layoutData
        gridLayoutCache[pageKey] = pageInfo
        os_unfair_lock_unlock(&cacheLock)
        
    }
    
    /// 计算页面信息
    private func calculatePageInfo(for items: [LaunchpadItem]) -> [PageInfo] {
        let itemsPerPage = 35
        let pageCount = (items.count + itemsPerPage - 1) / itemsPerPage
        
        var pages: [PageInfo] = []
        pages.reserveCapacity(pageCount)
        
        for pageIndex in 0..<pageCount {
            let startIndex = pageIndex * itemsPerPage
            let endIndex = min(startIndex + itemsPerPage, items.count)
            var appCount = 0
            var folderCount = 0
            var emptyCount = 0
            
            for item in items[startIndex..<endIndex] {
                switch item {
                case .app: appCount += 1
                case .folder: folderCount += 1
                case .empty: emptyCount += 1
                }
            }
            
            let pageInfo = PageInfo(
                pageIndex: pageIndex,
                startIndex: startIndex,
                endIndex: endIndex,
                appCount: appCount,
                folderCount: folderCount,
                emptyCount: emptyCount
            )
            
            pages.append(pageInfo)
        }
        
        return pages
    }
    
}

// MARK: - 缓存键生成（使用原始路径避免 hashValue 碰撞）
private func cacheKeyForIcon(_ appPath: String) -> String {
    return "icon_\(appPath)"
}

private func cacheKeyForAppInfo(_ appPath: String) -> String {
    return "appinfo_\(appPath)"
}

private func cacheKeyForGridLayout(_ layoutKey: String) -> String {
    return "grid_\(layoutKey)"
}

// MARK: - 网格布局缓存数据结构

private struct GridLayoutCacheData {
    let totalItems: Int
    let itemsPerPage: Int
    let columns: Int
    let rows: Int
    let pageCount: Int
}

private struct PageInfo {
    let pageIndex: Int
    let startIndex: Int
    let endIndex: Int
    let appCount: Int
    let folderCount: Int
    let emptyCount: Int
}

// MARK: - 缓存统计信息
