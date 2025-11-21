import Foundation
import AppKit
import SwiftData

struct FolderInfo: Identifiable, Equatable {
    // Cache for rendered folder icons to avoid re-drawing on every access
    private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256 // reasonable upper bound
        return cache
    }()

    // Build a cache key that reflects folder id, requested side, and the first 4 app ids
    private func folderIconCacheKey(side: CGFloat) -> String {
        let normalizedSide = max(16, side)
        let appIds = apps.prefix(4).map { $0.id }.joined(separator: ",")
        return "folderIcon:\(id):\(Int(normalizedSide)):[\(appIds)]"
    }

    let id: String
    var name: String
    var apps: [AppInfo]
    let createdAt: Date
    
    init(id: String = UUID().uuidString, name: String = NSLocalizedString("Untitled", comment: "Untitled"), apps: [AppInfo] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.apps = apps
        self.createdAt = createdAt
    }
    
    var folderIcon: NSImage { 
        // 每次访问都重新生成图标，确保反映最新的应用状态
        let icon = icon(of: 72)
        return icon
    }

    func icon(of side: CGFloat) -> NSImage {
        let normalizedSide = max(16, side)
        let key = folderIconCacheKey(side: normalizedSide) as NSString
        if let cached = Self.iconCache.object(forKey: key) {
            return cached
        }
        let icon = renderFolderIcon(side: normalizedSide)
        Self.iconCache.setObject(icon, forKey: key)
        return icon
    }

    private func renderFolderIcon(side: CGFloat) -> NSImage {
        return autoreleasepool { () -> NSImage in
            let size = NSSize(width: side, height: side)
            let image = NSImage(size: size)
            image.lockFocus()
            defer { image.unlockFocus() }

            if let ctx = NSGraphicsContext.current {
                ctx.imageInterpolation = .high
                ctx.shouldAntialias = true
            }

            let rect = NSRect(origin: .zero, size: size)

            let outerInset = round(side * 0.12)
            let contentRect = rect.insetBy(dx: outerInset, dy: outerInset)
            let innerInset = round(contentRect.width * 0.08)
            let innerRect = contentRect.insetBy(dx: innerInset, dy: innerInset)

            let spacing = max(2, round(innerRect.width * 0.04))
            let tile = floor((innerRect.width - spacing) / 2)
            let startX = innerRect.minX
            let topY = innerRect.maxY

            for (index, app) in apps.prefix(4).enumerated() {
                let rowTopFirst = index / 2
                let col = index % 2
                let x = startX + CGFloat(col) * (tile + spacing)
                let y = topY - CGFloat(rowTopFirst + 1) * tile - CGFloat(rowTopFirst) * spacing
                let iconRect = NSRect(x: x, y: y, width: tile, height: tile)

                // Fallback: if app icon is empty, use system file icon
                let iconToDraw: NSImage = {
                    if app.icon.size.width > 0 && app.icon.size.height > 0 {
                        return app.icon
                    } else {
                        return NSWorkspace.shared.icon(forFile: app.url.path)
                    }
                }()
                iconToDraw.draw(in: iconRect)
            }

            return image
        }
    }
    
    static func == (lhs: FolderInfo, rhs: FolderInfo) -> Bool {
        lhs.id == rhs.id
    }
}

enum LaunchpadItem: Identifiable, Equatable {
    // Shared transparent image to reduce allocations for empty placeholders
    private static let transparentImage: NSImage = {
        let size = NSSize(width: 1, height: 1)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        img.unlockFocus()
        return img
    }()

    case app(AppInfo)
    case folder(FolderInfo)
    case empty(String)
    
    var id: String {
        switch self {
        case .app(let app):
            return "app_\(app.id)"
        case .folder(let folder):
            return "folder_\(folder.id)"
        case .empty(let token):
            return "empty_\(token)"
        }
    }
    
    var name: String {
        switch self {
        case .app(let app):
            return app.name
        case .folder(let folder):
            return folder.name
        case .empty:
            return ""
        }
    }
    
    var icon: NSImage {
        switch self {
        case .app(let app):
            return app.icon
        case .folder(let folder):
            let icon = folder.folderIcon
            return icon
        case .empty:
            // Use shared transparent placeholder to minimize allocations
            return LaunchpadItem.transparentImage
        }
    }

    // 方便判断：若为 .app 返回 AppInfo，否则为 nil
    var appInfoIfApp: AppInfo? {
        if case let .app(app) = self { return app }
        return nil
    }
    
    static func == (lhs: LaunchpadItem, rhs: LaunchpadItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 统一持久化模型（顶层项：应用或文件夹）
@Model
final class TopItemData {
    // 统一主键：对于应用可使用 appPath，对于文件夹使用 folderId
    @Attribute(.unique) var id: String
    var kind: String                 // "app" or "folder"
    var orderIndex: Int              // 顶层混合顺序索引
    // 应用字段
    var appPath: String?
    // 文件夹字段
    var folderName: String?
    var appPaths: [String]           // 文件夹内的应用顺序
    // 时间戳
    var createdAt: Date
    var updatedAt: Date

    // 文件夹构造
    init(folderId: String,
         folderName: String,
         appPaths: [String],
         orderIndex: Int,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = folderId
        self.kind = "folder"
        self.orderIndex = orderIndex
        self.appPath = nil
        self.folderName = folderName
        self.appPaths = appPaths
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // 应用构造
    init(appPath: String,
         orderIndex: Int,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = appPath
        self.kind = "app"
        self.orderIndex = orderIndex
        self.appPath = appPath
        self.folderName = nil
        self.appPaths = []
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // 空槽位构造
    init(emptyId: String,
         orderIndex: Int,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = emptyId
        self.kind = "empty"
        self.orderIndex = orderIndex
        self.appPath = nil
        self.folderName = nil
        self.appPaths = []
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - 每页独立排序持久化模型（按“页-槽位”存储）
@Model
final class PageEntryData {
    // 槽位唯一键：例如 "page-0-pos-3"
    @Attribute(.unique) var slotId: String
    var pageIndex: Int
    var position: Int
    var kind: String          // "app" | "folder" | "empty"
    // app 条目
    var appPath: String?
    // folder 条目
    var folderId: String?
    var folderName: String?
    var appPaths: [String]
    // 时间戳
    var createdAt: Date
    var updatedAt: Date

    init(slotId: String,
         pageIndex: Int,
         position: Int,
         kind: String,
         appPath: String? = nil,
         folderId: String? = nil,
         folderName: String? = nil,
         appPaths: [String] = [],
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.slotId = slotId
        self.pageIndex = pageIndex
        self.position = position
        self.kind = kind
        self.appPath = appPath
        self.folderId = folderId
        self.folderName = folderName
        self.appPaths = appPaths
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
