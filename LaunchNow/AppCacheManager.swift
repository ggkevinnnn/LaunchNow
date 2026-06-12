import Foundation
import AppKit
import Combine
import os.lock

/// 应用缓存管理器 - 负责缓存应用图标和应用信息以提高性能
final class AppCacheManager: ObservableObject {
    static let shared = AppCacheManager()
    
    // MARK: - 缓存存储
    private let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500
        return cache
    }()
    private var appInfoCache: [String: AppInfo] = [:]
    private var cacheLock = os_unfair_lock()
    
    // MARK: - 缓存状态
    @Published var isCacheValid = false
    @Published var lastCacheUpdate = Date.distantPast
    
    private init() {}
    
    // MARK: - 公共接口
    
    /// 收集所有需要缓存的应用（包括文件夹内的应用），去重后返回
    private static func collectAllApps(_ apps: [AppInfo], from items: [LaunchpadItem]) -> [AppInfo] {
        var allApps = apps
        for item in items {
            if case let .folder(folder) = item {
                allApps.append(contentsOf: folder.apps)
            }
        }
        var uniqueApps: [AppInfo] = []
        var seenPaths = Set<String>()
        for app in allApps {
            if !seenPaths.contains(app.url.path) {
                seenPaths.insert(app.url.path)
                uniqueApps.append(app)
            }
        }
        return uniqueApps
    }
    
    /// 生成应用缓存 - 在应用启动或扫描后调用
    func generateCache(from apps: [AppInfo], items: [LaunchpadItem]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            
            self.clearAllCaches()
            
            let uniqueApps = Self.collectAllApps(apps, from: items)
            
            self.cacheAppInfos(uniqueApps)
            self.cacheAppIcons(uniqueApps)
            
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
    
    /// 预加载应用图标到缓存
    func preloadIcons(for appPaths: [String]) {
        preloadIcons(for: appPaths, completion: nil)
    }

    /// 预加载应用图标到缓存，并在完成后回调
    func preloadIcons(for appPaths: [String], completion: (() -> Void)?) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            
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
        let uniqueApps = Self.collectAllApps(apps, from: items)
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
    
}

// MARK: - 缓存键生成（使用原始路径避免 hashValue 碰撞）
private func cacheKeyForIcon(_ appPath: String) -> String {
    return "icon_\(appPath)"
}

private func cacheKeyForAppInfo(_ appPath: String) -> String {
    return "appinfo_\(appPath)"
}

// MARK: - 缓存统计信息
