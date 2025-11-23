import SwiftUI

enum LNAnimations {
    // MARK: - Springs - 优化性能的动画配置
    static let springFast: Animation = .spring(response: 0.35, dampingFraction: 0.8) // 更快的响应
    
    static let dragSnap: Animation = LNAnimations.springFast
    
    // MARK: - 性能优化的动画
    static let gridUpdate: Animation = .easeInOut(duration: 0.3) // 网格更新动画
    static let itemAppear: Animation = .easeInOut(duration: 0.2)
    
    // MARK: - Transitions
    static var folderOpenTransition: AnyTransition {
        .scale(scale: 0.8)
        .animation(LNAnimations.gridUpdate)
    }
}

