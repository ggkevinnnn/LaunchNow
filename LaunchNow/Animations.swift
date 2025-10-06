import SwiftUI

enum LNAnimations {
    // MARK: - Springs - 优化性能的动画配置
    static let springFast: Animation = .spring(response: 0.3, dampingFraction: 0.8) // 更快的响应
    
    // MARK: - 性能优化的动画
    static let dragPreview: Animation = .easeOut(duration: 0.3) // 拖拽预览使用更简单的动画
    static let gridUpdate: Animation = .easeInOut(duration: 0.3) // 网格更新动画
    
    // MARK: - Transitions
    static var folderOpenTransition: AnyTransition {
        .scale(scale: 0.8)
        .animation(LNAnimations.springFast)
    }
}


