import ApplicationServices
import CoreFoundation
import Darwin

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: UInt32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVector
    var zTotal: Float
    var field9: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

private typealias MTDeviceRef = UnsafeMutableRawPointer
private typealias MTContactCallback = @convention(c) (
    MTDeviceRef?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

private let mtTouchStateMakeTouch: UInt32 = 3
private let mtTouchStateTouching: UInt32 = 4
private let mtTouchStateBreakTouch: UInt32 = 5

private struct FrameTouch {
    let id: Int32
    let x: CGFloat
    let y: CGFloat
    let vx: CGFloat
    let vy: CGFloat
}

private struct PinchSession {
    var fingerIDs = Set<Int32>()
    var initialRadius: CGFloat?
    var filteredRadius: CGFloat?
    var smoothedRadius: CGFloat?
    var activeDirection: GlobalPinchGestureDirection?
    var currentProgress: CGFloat = 0
    var recognizedDirection: GlobalPinchGestureDirection?
    var lastTimestamp: Double = 0
    var velocity: CGFloat = 0
    var acceleration: CGFloat = 0
    var radiusHistory: [CGFloat] = []
    var timestampHistory: [Double] = []
}

enum GlobalPinchGestureDirection {
    case pinchIn
    case pinchOut
}

@MainActor
final class GlobalPinchGestureMonitor {
    static let shared = GlobalPinchGestureMonitor()

    private var multitouch: MultitouchAPI?
    private var onPinchIn: (() -> Void)?
    private var onPinchOut: (() -> Void)?
    private var onProgress: ((GlobalPinchGestureDirection, CGFloat) -> Void)?
    private var onGestureEnded: (() -> Void)?
    private var lastRecognitionAt = Date.distantPast
    private var sessionsByDeviceID: [UInt: PinchSession] = [:]
    private var pendingResetWorkItemsByDeviceID: [UInt: DispatchWorkItem] = [:]

    private let minimumTouchCount = 4
    private let pinchInRatioThreshold: CGFloat = 0.9
    private let pinchOutRatioThreshold: CGFloat = 1.1
    private let triggerCooldown: TimeInterval = 0.2
    private let radiusFilterFactor: CGFloat = 0.28
    private let progressDeadZone: CGFloat = 0.015
    private let directionStartDeadZone: CGFloat = 0.035
    private let directionSwitchDeadZone: CGFloat = 0.08
    private let gestureEndGracePeriod: TimeInterval = 0.12
    private let minimumVelocityThreshold: CGFloat = 0.005
    /// 最大角度聚类范围（弧度），小于此值视为滑动手势
    private let swipeAngleThreshold: CGFloat = .pi / 3  // 60°
    /// 双指数移动平均的平滑因子
    private let demaAlpha: CGFloat = 0.3
    private let demaBeta: CGFloat = 0.15
    /// 速度变化阈值，低于此值视为抖动
    private let velocityChangeThreshold: CGFloat = 0.002
    /// 加速度变化阈值，高于此值视为抖动
    private let accelerationThreshold: CGFloat = 0.01
    /// 历史数据窗口大小
    private let historyWindowSize: Int = 5

    private init() {}

    func start(
        promptForAccessibility: Bool,
        onPinchIn: @escaping () -> Void,
        onPinchOut: @escaping () -> Void,
        onProgress: @escaping (GlobalPinchGestureDirection, CGFloat) -> Void,
        onGestureEnded: @escaping () -> Void
    ) {
        self.onPinchIn = onPinchIn
        self.onPinchOut = onPinchOut
        self.onProgress = onProgress
        self.onGestureEnded = onGestureEnded
        if promptForAccessibility {
            requestAccessibilityTrustIfNeeded()
        }

        if multitouch == nil {
            do {
                let api = try MultitouchAPI()
                try api.start()
                multitouch = api
            } catch {
                NSLog("LaunchNow: failed to start global pinch monitor: \(String(describing: error))")
            }
        }
    }

    func stop() {
        for workItem in pendingResetWorkItemsByDeviceID.values {
            workItem.cancel()
        }
        pendingResetWorkItemsByDeviceID.removeAll()
        sessionsByDeviceID.removeAll()
        onPinchIn = nil
        onPinchOut = nil
        onProgress = nil
        onGestureEnded = nil
        multitouch?.stop()
        multitouch = nil
    }

    fileprivate nonisolated static let callback: MTContactCallback = { device, touchesRawPointer, touchCount, _, _ in
        let deviceID = device.map { UInt(bitPattern: $0) } ?? 0
        guard let touchesRawPointer, touchCount > 0 else {
            Task { @MainActor in
                GlobalPinchGestureMonitor.shared.scheduleSessionReset(for: deviceID)
            }
            return 0
        }

        let touchesPointer = touchesRawPointer.bindMemory(to: MTTouch.self, capacity: Int(touchCount))
        let buffer = UnsafeBufferPointer(start: touchesPointer, count: Int(touchCount))
        let makeTouch = mtTouchStateMakeTouch
        let touching = mtTouchStateTouching
        let activeTouches = buffer.compactMap { touch -> FrameTouch? in
            guard touch.state == makeTouch ||
                    touch.state == touching else {
                return nil
            }
            return FrameTouch(
                id: touch.pathIndex >= 0 ? touch.pathIndex : touch.fingerID,
                x: CGFloat(touch.normalizedVector.position.x),
                y: CGFloat(touch.normalizedVector.position.y),
                vx: CGFloat(touch.normalizedVector.velocity.x),
                vy: CGFloat(touch.normalizedVector.velocity.y)
            )
        }

        Task { @MainActor in
            GlobalPinchGestureMonitor.shared.process(activeTouches: activeTouches, deviceID: deviceID)
        }
        return 0
    }

    private func process(activeTouches: [FrameTouch], deviceID: UInt) {
        var session = sessionsByDeviceID[deviceID] ?? PinchSession()

        guard activeTouches.count >= minimumTouchCount else {
            scheduleSessionReset(for: deviceID)
            return
        }

        let touches = Array(activeTouches.sorted { $0.id < $1.id }.prefix(minimumTouchCount))
        let ids = Set(touches.map(\.id))
        if ids.count < minimumTouchCount {
            scheduleSessionReset(for: deviceID)
            return
        }

        cancelScheduledReset(for: deviceID)

        if session.fingerIDs.isEmpty {
            session = PinchSession()
            session.fingerIDs = ids
            sessionsByDeviceID[deviceID] = session
        } else if session.fingerIDs != ids {
            session.fingerIDs = ids
        }

        // 速度方向聚类检测：若 3+ 手指有明显运动且方向一致，判定为滑动，不处理
        let movingCount = touches.filter { hypot($0.vx, $0.vy) > minimumVelocityThreshold }.count
        if movingCount >= 3 && isSwipeGesture(touches: touches) {
            if session.initialRadius == nil {
                resetSession(for: deviceID)
            } else {
                sessionsByDeviceID[deviceID] = session
            }
            return
        }

        let center = CGPoint(
            x: touches.map(\.x).reduce(0, +) / CGFloat(touches.count),
            y: touches.map(\.y).reduce(0, +) / CGFloat(touches.count)
        )
        let radius = touches.reduce(CGFloat.zero) { partial, touch in
            partial + hypot(touch.x - center.x, touch.y - center.y)
        } / CGFloat(touches.count)

        if session.initialRadius == nil {
            session.initialRadius = radius
            session.filteredRadius = radius
            session.smoothedRadius = radius
            session.lastTimestamp = Date().timeIntervalSince1970
            session.radiusHistory = [radius]
            session.timestampHistory = [session.lastTimestamp]
            sessionsByDeviceID[deviceID] = session
            return
        }

        guard
            let initialRadius = session.initialRadius,
            let previousFilteredRadius = session.filteredRadius,
            let previousSmoothedRadius = session.smoothedRadius,
            initialRadius > 0
        else {
            return
        }

        let now = Date().timeIntervalSince1970
        let deltaTime = now - session.lastTimestamp
        session.lastTimestamp = now

        // 基础滤波
        let filteredRadius = previousFilteredRadius + (radius - previousFilteredRadius) * radiusFilterFactor
        session.filteredRadius = filteredRadius

        // 计算速度和加速度
        let newVelocity = deltaTime > 0 ? (filteredRadius - previousSmoothedRadius) / deltaTime : 0
        let newAcceleration = deltaTime > 0 ? (newVelocity - session.velocity) / deltaTime : 0

        // 检测加速度突变（抖动）
        if abs(newAcceleration) > accelerationThreshold {
            // 加速度突变，可能是抖动，使用更保守的滤波
            session.velocity = session.velocity * 0.5 + newVelocity * 0.5
            session.acceleration = newAcceleration
        } else {
            session.velocity = newVelocity
            session.acceleration = newAcceleration
        }

        // 检测速度变化是否过小（可能是抖动）
        if abs(session.velocity) < velocityChangeThreshold && deltaTime > 0 {
            // 速度变化过小，可能是抖动，保持之前的值
            session.smoothedRadius = previousSmoothedRadius
        } else {
            // 使用双指数移动平均（DEMA）进一步平滑
            let ema1 = previousSmoothedRadius + (filteredRadius - previousSmoothedRadius) * demaAlpha
            let ema2 = previousSmoothedRadius + (ema1 - previousSmoothedRadius) * demaAlpha
            let dema = 2 * ema1 - ema2
            session.smoothedRadius = dema
        }

        // 更新历史数据
        session.radiusHistory.append(filteredRadius)
        session.timestampHistory.append(now)
        if session.radiusHistory.count > historyWindowSize {
            session.radiusHistory.removeFirst()
            session.timestampHistory.removeFirst()
        }

        // 使用历史数据的加权平均作为最终半径
        let finalRadius: CGFloat
        if session.radiusHistory.count >= 3 {
            let weights = Array(1...session.radiusHistory.count).map { CGFloat($0) }
            let totalWeight = weights.reduce(0, +)
            finalRadius = zip(session.radiusHistory, weights).map { $0 * $1 }.reduce(0, +) / totalWeight
        } else {
            finalRadius = session.smoothedRadius ?? filteredRadius
        }

        let radiusRatio = finalRadius / initialRadius
        let ratioDelta = radiusRatio - 1
        let movementMagnitude = abs(ratioDelta)
        let candidateDirection: GlobalPinchGestureDirection = ratioDelta < 0 ? .pinchIn : .pinchOut

        if session.activeDirection == nil {
            guard movementMagnitude >= directionStartDeadZone else {
                sessionsByDeviceID[deviceID] = session
                return
            }
            session.activeDirection = candidateDirection
            session.currentProgress = 0
        } else if session.activeDirection != candidateDirection {
            guard movementMagnitude >= directionSwitchDeadZone else {
                if let direction = session.activeDirection, session.currentProgress > 0 {
                    onProgress?(direction, session.currentProgress)
                }
                sessionsByDeviceID[deviceID] = session
                return
            }
            session.activeDirection = candidateDirection
            session.currentProgress = 0
            session.recognizedDirection = nil
        }

        guard let activeDirection = session.activeDirection else {
            sessionsByDeviceID[deviceID] = session
            return
        }

        let rawProgress: CGFloat
        switch activeDirection {
        case .pinchIn:
            rawProgress = (1 - radiusRatio) / (1 - pinchInRatioThreshold)
        case .pinchOut:
            rawProgress = (radiusRatio - 1) / (pinchOutRatioThreshold - 1)
        }

        let clampedProgress = max(0, min(1, rawProgress))
        if clampedProgress < progressDeadZone, session.currentProgress == 0 {
            sessionsByDeviceID[deviceID] = session
            return
        }

        session.currentProgress = max(session.currentProgress, clampedProgress)
        onProgress?(activeDirection, session.currentProgress)

        let recognitionNow = Date()
        guard recognitionNow.timeIntervalSince(lastRecognitionAt) >= triggerCooldown else {
            sessionsByDeviceID[deviceID] = session
            return
        }

        if activeDirection == .pinchIn,
           session.currentProgress >= 1,
           session.recognizedDirection != .pinchIn {
            lastRecognitionAt = recognitionNow
            session.recognizedDirection = .pinchIn
            session.currentProgress = 1
            sessionsByDeviceID[deviceID] = session
            onPinchIn?()
            return
        }

        if activeDirection == .pinchOut,
           session.currentProgress >= 1,
           session.recognizedDirection != .pinchOut {
            lastRecognitionAt = recognitionNow
            session.recognizedDirection = .pinchOut
            session.currentProgress = 1
            sessionsByDeviceID[deviceID] = session
            onPinchOut?()
            return
        }

        sessionsByDeviceID[deviceID] = session
    }

    /// 判断手指速度方向是否高度一致（聚类于小角度范围），若是则判定为滑动手势。
    private func isSwipeGesture(touches: [FrameTouch]) -> Bool {
        guard touches.count >= 4 else { return false }

        let angles = touches.map { atan2($0.vy, $0.vx) }
        let sorted = angles.sorted()
        let n = sorted.count

        var maxGap: CGFloat = 0
        for i in 0..<n {
            var gap = sorted[(i + 1) % n] - sorted[i]
            if gap < 0 { gap += 2 * .pi }
            maxGap = max(maxGap, gap)
        }

        // 最大间隙的补角即为所有角度的聚类范围
        let clusterRange = 2 * .pi - maxGap
        return clusterRange < swipeAngleThreshold
    }

    private func resetSession(for deviceID: UInt) {
        cancelScheduledReset(for: deviceID)
        guard let session = sessionsByDeviceID[deviceID] else { return }
        let hasOtherActiveSession = sessionsByDeviceID.contains { otherDeviceID, otherSession in
            otherDeviceID != deviceID && otherSession.initialRadius != nil
        }
        if session.initialRadius != nil && !hasOtherActiveSession {
            onGestureEnded?()
        }
        sessionsByDeviceID.removeValue(forKey: deviceID)
    }

    private func scheduleSessionReset(for deviceID: UInt) {
        guard sessionsByDeviceID[deviceID]?.initialRadius != nil else {
            resetSession(for: deviceID)
            return
        }

        pendingResetWorkItemsByDeviceID[deviceID]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.resetSession(for: deviceID)
        }
        pendingResetWorkItemsByDeviceID[deviceID] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + gestureEndGracePeriod, execute: workItem)
    }

    private func cancelScheduledReset(for deviceID: UInt) {
        pendingResetWorkItemsByDeviceID[deviceID]?.cancel()
        pendingResetWorkItemsByDeviceID.removeValue(forKey: deviceID)
    }

    private func requestAccessibilityTrustIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

private final class MultitouchAPI {
    private typealias CreateListFunc = @convention(c) () -> CFArray?
    private typealias RegisterCallbackFunc = @convention(c) (MTDeviceRef, MTContactCallback) -> Void
    private typealias UnregisterCallbackFunc = @convention(c) (MTDeviceRef, MTContactCallback?) -> Void
    private typealias StartDeviceFunc = @convention(c) (MTDeviceRef, Int32) -> Int32
    private typealias StopDeviceFunc = @convention(c) (MTDeviceRef) -> Int32

    private let handle: UnsafeMutableRawPointer
    private let createList: CreateListFunc
    private let registerCallback: RegisterCallbackFunc
    private let unregisterCallback: UnregisterCallbackFunc?
    private let startDevice: StartDeviceFunc
    private let stopDevice: StopDeviceFunc?
    private var devices: [MTDeviceRef] = []

    init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW) else {
            throw MonitorError.libraryUnavailable
        }
        self.handle = handle

        guard
            let createList = MultitouchAPI.loadSymbol("MTDeviceCreateList", from: handle, as: CreateListFunc.self),
            let registerCallback = MultitouchAPI.loadSymbol("MTRegisterContactFrameCallback", from: handle, as: RegisterCallbackFunc.self),
            let startDevice = MultitouchAPI.loadSymbol("MTDeviceStart", from: handle, as: StartDeviceFunc.self)
        else {
            dlclose(handle)
            throw MonitorError.symbolMissing
        }

        self.createList = createList
        self.registerCallback = registerCallback
        self.unregisterCallback = MultitouchAPI.loadSymbol("MTUnregisterContactFrameCallback", from: handle, as: UnregisterCallbackFunc.self)
        self.startDevice = startDevice
        self.stopDevice = MultitouchAPI.loadSymbol("MTDeviceStop", from: handle, as: StopDeviceFunc.self)
    }

    deinit {
        dlclose(handle)
    }

    func start() throws {
        guard let list = createList() else {
            throw MonitorError.deviceListUnavailable
        }

        let count = CFArrayGetCount(list)
        for index in 0 ..< count {
            let value = CFArrayGetValueAtIndex(list, index)
            let device = unsafeBitCast(value, to: MTDeviceRef.self)
            registerCallback(device, GlobalPinchGestureMonitor.callback)
            _ = startDevice(device, 0)
            devices.append(device)
        }

        if devices.isEmpty {
            throw MonitorError.noTrackpadDevice
        }
    }

    func stop() {
        let devices = devices
        self.devices.removeAll()

        for device in devices {
            unregisterCallback?(device, GlobalPinchGestureMonitor.callback)
        }

        guard let stopDevice else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            for device in devices {
                _ = stopDevice(device)
            }
        }
    }

    private static func loadSymbol<T>(_ name: String, from handle: UnsafeMutableRawPointer, as type: T.Type) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    enum MonitorError: Error {
        case libraryUnavailable
        case symbolMissing
        case deviceListUnavailable
        case noTrackpadDevice
    }
}
