import Foundation
import SwiftUI

// MARK: - Shared Geometry Utilities
struct GeometryUtils {
    static func cellOrigin(for index: Int,
                          containerSize: CGSize,
                          pageIndex: Int,
                          columnWidth: CGFloat,
                          appHeight: CGFloat,
                          columns: Int,
                          columnSpacing: CGFloat,
                          rowSpacing: CGFloat,
                          pageSpacing: CGFloat,
                          currentPage: Int,
                          gridPadding: CGFloat = 0,
                          scrollOffsetY: CGFloat = 0) -> CGPoint {
        let row = index / columns
        let col = index % columns
        
        let x = gridPadding + CGFloat(col) * (columnWidth + columnSpacing)
        let y = gridPadding + CGFloat(row) * (appHeight + rowSpacing) - scrollOffsetY
        
        // For multi-page layouts
        let effectivePageOffsetX = CGFloat(pageIndex - currentPage) * (containerSize.width + pageSpacing)
        
        return CGPoint(x: x + effectivePageOffsetX, y: y)
    }
    
    static func cellCenter(for index: Int,
                           containerSize: CGSize,
                           pageIndex: Int,
                           columnWidth: CGFloat,
                           appHeight: CGFloat,
                           columns: Int,
                           columnSpacing: CGFloat,
                           rowSpacing: CGFloat,
                           pageSpacing: CGFloat,
                           currentPage: Int,
                           gridPadding: CGFloat = 0,
                           scrollOffsetY: CGFloat = 0) -> CGPoint {
        let origin = cellOrigin(for: index,
                               containerSize: containerSize,
                               pageIndex: pageIndex,
                               columnWidth: columnWidth,
                               appHeight: appHeight,
                               columns: columns,
                               columnSpacing: columnSpacing,
                               rowSpacing: rowSpacing,
                               pageSpacing: pageSpacing,
                               currentPage: currentPage,
                               gridPadding: gridPadding,
                               scrollOffsetY: scrollOffsetY)
        return CGPoint(x: origin.x + columnWidth / 2, y: origin.y + appHeight / 2)
    }
    
    static func indexAt(point: CGPoint,
                        containerSize: CGSize,
                        pageIndex: Int,
                        columnWidth: CGFloat,
                        appHeight: CGFloat,
                        columns: Int,
                        columnSpacing: CGFloat,
                        rowSpacing: CGFloat,
                        pageSpacing: CGFloat,
                        currentPage: Int,
                        itemsPerPage: Int,
                        gridPadding: CGFloat = 0,
                        scrollOffsetY: CGFloat = 0,
                        pageItems: [Any]? = nil) -> Int? {
        let pageOffsetX = CGFloat(pageIndex - currentPage) * (containerSize.width + pageSpacing)
        let localX = point.x - pageOffsetX - gridPadding
        let localY = point.y - gridPadding + scrollOffsetY
        
        guard localX >= 0, localY >= 0 else { return nil }
        
        let col = Int((localX + columnSpacing / 2) / (columnWidth + columnSpacing))
        let row = Int((localY + rowSpacing / 2) / (appHeight + rowSpacing))
        
        guard col >= 0 && col < columns && row >= 0 else { return nil }
        
        let offsetInPage = row * columns + col
        guard offsetInPage >= 0 && offsetInPage < itemsPerPage else { return nil }
        
        if let pageItems = pageItems {
            guard pageItems.indices.contains(offsetInPage) else { return nil }
        }
        
        return offsetInPage
    }
}
