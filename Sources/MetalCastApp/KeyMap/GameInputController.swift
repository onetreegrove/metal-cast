import AppKit
import MetalCastCore

@MainActor
public final class GameInputController: ObservableObject {
    public weak var inputController: InputController?

    @Published public private(set) var isGameModeActive: Bool = false
    @Published public private(set) var isCursorTemporarilyReleased: Bool = false
    @Published public private(set) var currentProfileName: String = ""

    public var onHUDMessage: ((String) -> Void)?

    private var profile: KeyMapProfile?

    // Fast-lookup trigger maps
    private var switchTrigger: InputTrigger = .key(50) // Default `~` (QuoteLeft)
    private var clickNodesMap: [InputTrigger: KeyMapNodeConfig] = [:]
    private var dragNodesMap: [InputTrigger: KeyMapNodeConfig] = [:]
    private var multiClickNodesMap: [InputTrigger: KeyMapNodeConfig] = [:]
    private var steerWheelNode: KeyMapNodeConfig?
    private var mouseMoveConfig: MouseMoveMapConfig?
    private var smallEyesTrigger: InputTrigger?

    // Pointer IDs
    private let steerWheelPointerId: UInt64 = 1
    private let mouseLookPointerId: UInt64 = 2
    private let smallEyesPointerId: UInt64 = 3
    private let dragPointerId: UInt64 = 55
    private var activePointerIds: [InputTrigger: UInt64] = [:]
    private var activeEphemeralPointerIds: Set<UInt64> = []
    private var nextDynamicPointerId: UInt64 = 10
    private var isDragActive: Bool = false
    private var lastDragEndPos: CGPoint = .zero
    private var isPointerLocked: Bool = false
    private var currentMouseLookPointerId: UInt64 = 2

    // Steer Wheel (WASD) state
    private var steerUpTrigger: InputTrigger?
    private var steerDownTrigger: InputTrigger?
    private var steerLeftTrigger: InputTrigger?
    private var steerRightTrigger: InputTrigger?
    private var isSteerUpPressed = false
    private var isSteerDownPressed = false
    private var isSteerLeftPressed = false
    private var isSteerRightPressed = false
    private var isSteerTouching = false
    private var currentSteerPos: CGPoint = .zero

    // Mouse Look state & pacing
    private var isMouseLookTouching = false
    private var currentMouseLookPos: CGPoint = .zero
    private var mouseLookIdleTimer: Timer?
    private var lastMouseMoveTime: CFTimeInterval = 0
    private var lastMouseMoveSendTime: CFTimeInterval = 0
    private var lastSentMovePositions: [UInt64: (x: Int32, y: Int32)] = [:]
    private var isSmallEyesActive = false

    public init(inputController: InputController? = nil) {
        self.inputController = inputController
    }

    // MARK: - Configuration & Profile Loading

    public func setProfile(_ profile: KeyMapProfile?, name: String = "") {
        deactivateGameMode()
        self.profile = profile
        self.currentProfileName = name
        rebuildLookupTables()
    }

    private func rebuildLookupTables() {
        clickNodesMap.removeAll()
        dragNodesMap.removeAll()
        multiClickNodesMap.removeAll()
        steerWheelNode = nil
        mouseMoveConfig = nil
        smallEyesTrigger = nil
        steerUpTrigger = nil
        steerDownTrigger = nil
        steerLeftTrigger = nil
        steerRightTrigger = nil

        guard let profile = self.profile else { return }

        // 1. Switch Key
        if let swStr = profile.switchKey, let tr = KeyMappingConverter.parseTrigger(from: swStr) {
            self.switchTrigger = normalizeTrigger(tr)
        } else {
            self.switchTrigger = .key(50) // Default `~`
        }

        // 2. Mouse Move Map
        if let mm = profile.mouseMoveMap {
            self.mouseMoveConfig = mm
            if let se = mm.smallEyes, let seTr = KeyMappingConverter.parseTrigger(from: se.key) {
                self.smallEyesTrigger = normalizeTrigger(seTr)
            }
        }

        // 3. Key Map Nodes
        for node in profile.keyMapNodes {
            switch node.type {
            case .steerWheel:
                self.steerWheelNode = node
                if let k = node.upKey, let tr = KeyMappingConverter.parseTrigger(from: k) {
                    self.steerUpTrigger = normalizeTrigger(tr)
                }
                if let k = node.downKey, let tr = KeyMappingConverter.parseTrigger(from: k) {
                    self.steerDownTrigger = normalizeTrigger(tr)
                }
                if let k = node.leftKey, let tr = KeyMappingConverter.parseTrigger(from: k) {
                    self.steerLeftTrigger = normalizeTrigger(tr)
                }
                if let k = node.rightKey, let tr = KeyMappingConverter.parseTrigger(from: k) {
                    self.steerRightTrigger = normalizeTrigger(tr)
                }

            case .click, .clickTwice, .androidKey:
                if let k = node.key, let tr = KeyMappingConverter.parseTrigger(from: k) {
                    clickNodesMap[normalizeTrigger(tr)] = node
                }

            case .clickMulti:
                if let k = node.key, let tr = KeyMappingConverter.parseTrigger(from: k) {
                    multiClickNodesMap[normalizeTrigger(tr)] = node
                }

            case .drag:
                if let k = node.key, let tr = KeyMappingConverter.parseTrigger(from: k) {
                    dragNodesMap[normalizeTrigger(tr)] = node
                }
            }
        }
    }

    private func normalizeTrigger(_ trigger: InputTrigger) -> InputTrigger {
        switch trigger {
        case .key(60): return .key(56) // Right Shift -> Left Shift
        case .key(61): return .key(58) // Right Option -> Left Option
        case .key(62): return .key(59) // Right Control -> Left Control
        case .key(54): return .key(55) // Right Command -> Left Command
        default: return trigger
        }
    }

    // MARK: - Game Mode Toggle & Pointer Locking

    public func toggleGameMode() {
        if isGameModeActive {
            deactivateGameMode()
        } else {
            activateGameMode()
        }
    }

    public func activateGameMode() {
        guard profile != nil else { return }
        isGameModeActive = true
        isCursorTemporarilyReleased = false

        lockPointer(true)
        onHUDMessage?("🎮 键鼠映射已激活 · 按 [\(switchTrigger.displayName)] 释放鼠标")
    }

    public func deactivateGameMode() {
        guard isGameModeActive else { return }
        isGameModeActive = false
        isCursorTemporarilyReleased = false

        releaseAllTouches()
        lockPointer(false)
        onHUDMessage?("🖱️ 鼠标已释放 · 恢复普通桌面交互")
    }

    private func lockPointer(_ lock: Bool) {
        guard isPointerLocked != lock else { return }
        isPointerLocked = lock
        if lock {
            CGAssociateMouseAndMouseCursorPosition(0) // false: Freeze cursor position
            NSCursor.hide()
        } else {
            CGAssociateMouseAndMouseCursorPosition(1) // true: Restore normal movement
            NSCursor.unhide()
        }
    }

    private func toggleTemporaryPointerRelease() {
        isCursorTemporarilyReleased.toggle()
        if isCursorTemporarilyReleased {
            lockPointer(false)
            onHUDMessage?("🖱️ 临时鼠标模式 · 点击背包/地图 (按对应键恢复视角)")
        } else {
            lockPointer(true)
            onHUDMessage?("🎮 视角已重新锁定")
        }
    }

    // MARK: - Event Dispatchers

    /// Returns true if the key event was intercepted and consumed by GameInputController
    public func handleKeyDown(with event: NSEvent) -> Bool {
        guard profile != nil else { return false }
        let trigger = normalizeTrigger(InputTrigger.key(event.keyCode))

        // 1. Switch Key toggle
        if trigger == switchTrigger {
            if event.isARepeat { return true }
            if isCursorTemporarilyReleased {
                toggleTemporaryPointerRelease()
            } else {
                toggleGameMode()
            }
            return true
        }

        // Ignore auto-repeat key downs for triggers to prevent repeated toggles / clicks
        if event.isARepeat {
            return isGameModeActive
        }

        // If game mode is not active, let normal input pass through
        guard isGameModeActive else { return false }

        // If pointer is temporarily released (e.g. Map / Inventory open), allow switchMap key to send touch down without toggling
        if isCursorTemporarilyReleased {
            if let node = clickNodesMap[trigger], node.switchMap == true {
                processKeyClick(trigger: trigger, node: node, isDown: true)
                return true
            }
            return false // Pass through so user can interact
        }

        // Small Eyes (Alt)
        if trigger == smallEyesTrigger {
            isSmallEyesActive = true
            stopMouseLookTouch()
            return true
        }

        // Steer Wheel (WASD)
        if isSteerWheelTrigger(trigger) {
            updateSteerKey(trigger: trigger, isPressed: true)
            return true
        }

        // Single / Twice / Android Key Clicks
        if let node = clickNodesMap[trigger] {
            processKeyClick(trigger: trigger, node: node, isDown: true)
            return true
        }

        // Multi Clicks
        if let node = multiClickNodesMap[trigger] {
            processMultiClick(node: node)
            return true
        }

        // Drag gestures
        if let node = dragNodesMap[trigger] {
            processDrag(node: node)
            return true
        }

        return false
    }

    /// Returns true if the key up event was intercepted and consumed
    public func handleKeyUp(with event: NSEvent) -> Bool {
        guard profile != nil, isGameModeActive else { return false }
        let trigger = normalizeTrigger(InputTrigger.key(event.keyCode))

        if trigger == switchTrigger {
            return true
        }

        if isCursorTemporarilyReleased {
            if let node = clickNodesMap[trigger], node.switchMap == true {
                processKeyClick(trigger: trigger, node: node, isDown: false)
                return true
            }
            return false
        }

        // Small Eyes (Alt)
        if trigger == smallEyesTrigger {
            isSmallEyesActive = false
            stopMouseLookTouch()
            return true
        }

        // Steer Wheel (WASD)
        if isSteerWheelTrigger(trigger) {
            updateSteerKey(trigger: trigger, isPressed: false)
            return true
        }

        // Key Clicks
        if let node = clickNodesMap[trigger] {
            processKeyClick(trigger: trigger, node: node, isDown: false)
            return true
        }

        return false
    }

    /// Mouse down handler
    public func handleMouseDown(button: Int) -> Bool {
        guard profile != nil else { return false }
        let trigger = InputTrigger.mouseButton(button)

        if trigger == switchTrigger {
            toggleGameMode()
            return true
        }

        guard isGameModeActive && !isCursorTemporarilyReleased else { return false }

        if let node = clickNodesMap[trigger] {
            processKeyClick(trigger: trigger, node: node, isDown: true)
            return true
        }
        return false
    }

    /// Mouse up handler
    public func handleMouseUp(button: Int) -> Bool {
        guard profile != nil else { return false }
        let trigger = InputTrigger.mouseButton(button)

        if trigger == switchTrigger {
            return true
        }

        guard isGameModeActive, !isCursorTemporarilyReleased else { return false }

        if let node = clickNodesMap[trigger] {
            processKeyClick(trigger: trigger, node: node, isDown: false)
            return true
        }
        return false
    }

    /// Mouse movement / camera pan handler with continuous optical deltas
    public func handleMouseMove(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        guard isGameModeActive, !isCursorTemporarilyReleased, let mm = mouseMoveConfig else {
            return false
        }

        guard deltaX != 0 || deltaY != 0 else { return true }

        let targetPointerId = isSmallEyesActive ? smallEyesPointerId : mouseLookPointerId
        let baseStartPos: KeyMapPosition
        if isSmallEyesActive, let sePos = mm.smallEyes?.pos {
            baseStartPos = sePos
        } else {
            baseStartPos = mm.startPos
        }

        let speedX = mm.effectiveSpeedRatioX
        let speedY = mm.effectiveSpeedRatioY

        // Convert deltas into normalized [0, 1] screen offset
        // In macOS AppKit, deltaY > 0 when mouse moves UP towards top of screen.
        // On phone touchscreen, Y = 0 is top, so moving mouse UP should decrease Y.
        let dx = Double(deltaX) / (speedX * 600.0)
        let dy = -Double(deltaY) / (speedY * 600.0)

        if !isMouseLookTouching {
            currentMouseLookPointerId = targetPointerId
            currentMouseLookPos = CGPoint(x: baseStartPos.x, y: baseStartPos.y)
            injectTouch(action: .down, pointerId: currentMouseLookPointerId, normPos: currentMouseLookPos)
            isMouseLookTouching = true
            lastMouseMoveSendTime = CACurrentMediaTime()
        }

        currentMouseLookPos.x += dx
        currentMouseLookPos.y += dy

        // Boundary Reset (Infinite Pan)
        // Cleanly lift touch on edge so the very next mouse movement seamlessly re-enters at startPos
        if currentMouseLookPos.x < 0.08 || currentMouseLookPos.x > 0.92 ||
           currentMouseLookPos.y < 0.08 || currentMouseLookPos.y > 0.92 {
            injectTouch(action: .up, pointerId: currentMouseLookPointerId, normPos: currentMouseLookPos)
            isMouseLookTouching = false
            return true
        }

        // Pacing: cap mouse look touch move rate to ~240Hz (interval 4ms) to protect Android socket
        let now = CACurrentMediaTime()
        if now - lastMouseMoveSendTime >= 0.004 {
            injectTouch(action: .move, pointerId: currentMouseLookPointerId, normPos: currentMouseLookPos)
            lastMouseMoveSendTime = now
        }

        lastMouseMoveTime = now
        if mouseLookIdleTimer == nil {
            scheduleMouseLookIdleTimer()
        }
        return true
    }

    private func scheduleMouseLookIdleTimer() {
        mouseLookIdleTimer?.invalidate()
        mouseLookIdleTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let elapsed = CACurrentMediaTime() - self.lastMouseMoveTime
                if elapsed >= 0.35 {
                    self.stopMouseLookTouch()
                    self.mouseLookIdleTimer = nil
                } else {
                    self.scheduleMouseLookIdleTimer()
                }
            }
        }
    }

    private func stopMouseLookTouch() {
        mouseLookIdleTimer?.invalidate()
        mouseLookIdleTimer = nil
        if isMouseLookTouching {
            injectTouch(action: .up, pointerId: currentMouseLookPointerId, normPos: currentMouseLookPos)
            isMouseLookTouching = false
        }
    }

    // MARK: - Steer Wheel (WASD Virtual Joystick)

    private func isSteerWheelTrigger(_ trigger: InputTrigger) -> Bool {
        return trigger == steerUpTrigger || trigger == steerDownTrigger ||
               trigger == steerLeftTrigger || trigger == steerRightTrigger
    }

    private func updateSteerKey(trigger: InputTrigger, isPressed: Bool) {
        guard let node = steerWheelNode, let center = node.centerPos else { return }

        if trigger == steerUpTrigger { isSteerUpPressed = isPressed }
        if trigger == steerDownTrigger { isSteerDownPressed = isPressed }
        if trigger == steerLeftTrigger { isSteerLeftPressed = isPressed }
        if trigger == steerRightTrigger { isSteerRightPressed = isPressed }

        let anyPressed = isSteerUpPressed || isSteerDownPressed || isSteerLeftPressed || isSteerRightPressed

        if !anyPressed {
            if isSteerTouching {
                injectTouch(action: .up, pointerId: steerWheelPointerId, normPos: currentSteerPos)
                isSteerTouching = false
            }
            return
        }

        var dx = 0.0
        var dy = 0.0
        if isSteerRightPressed { dx += (node.rightOffset ?? 0.12) }
        if isSteerLeftPressed  { dx -= (node.leftOffset ?? 0.12) }
        if isSteerUpPressed    { dy -= (node.upOffset ?? 0.22) }
        if isSteerDownPressed  { dy += (node.downOffset ?? 0.18) }

        let targetPos = CGPoint(x: center.x + dx, y: center.y + dy)

        if !isSteerTouching {
            currentSteerPos = CGPoint(x: center.x, y: center.y)
            injectTouch(action: .down, pointerId: steerWheelPointerId, normPos: currentSteerPos)
            isSteerTouching = true
        }

        currentSteerPos = targetPos
        injectTouch(action: .move, pointerId: steerWheelPointerId, normPos: currentSteerPos)
    }

    // MARK: - Key Click Processing

    private func processKeyClick(trigger: InputTrigger, node: KeyMapNodeConfig, isDown: Bool) {
        // Handle android keycode injection if specified
        if let ak = node.androidKey, ak > 0 {
            if isDown {
                inputController?.sendKeycode(UInt32(ak))
            }
            return
        }

        guard let pos = node.pos else { return }
        let cgPos = CGPoint(x: pos.x, y: pos.y)

        if node.type == .clickTwice {
            // Tap on press and tap again on release (e.g. peek/lean)
            // Use ephemeral pointer IDs in range 35...39 so rapid presses/releases never collide
            var ephemeralPid: UInt64 = 35
            for id: UInt64 in 35...39 {
                if !activeEphemeralPointerIds.contains(id) {
                    ephemeralPid = id
                    break
                }
            }
            activeEphemeralPointerIds.insert(ephemeralPid)
            injectTouch(action: .down, pointerId: ephemeralPid, normPos: cgPos)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self = self, self.isGameModeActive else { return }
                self.injectTouch(action: .up, pointerId: ephemeralPid, normPos: cgPos)
                self.activeEphemeralPointerIds.remove(ephemeralPid)
            }
            return
        }

        // Standard KMT_CLICK
        if isDown {
            let pid = allocatePointerId(for: trigger)
            injectTouch(action: .down, pointerId: pid, normPos: cgPos)
        } else {
            if let pid = activePointerIds[trigger] {
                injectTouch(action: .up, pointerId: pid, normPos: cgPos)
                freePointerId(for: trigger)
            }
            // If this key switches map (e.g. Tab/M), toggle cursor release on key up
            if node.switchMap == true {
                toggleTemporaryPointerRelease()
            }
        }
    }

    private func processMultiClick(node: KeyMapNodeConfig) {
        guard let clickNodes = node.clickNodes, !clickNodes.isEmpty else { return }

        var accumulatedDelay: Double = 0
        for (idx, click) in clickNodes.enumerated() {
            accumulatedDelay += Double(max(0, click.delay)) / 1000.0
            let pos = CGPoint(x: click.pos.x, y: click.pos.y)
            let tempPid: UInt64 = 40 + UInt64(idx % 10)

            DispatchQueue.main.asyncAfter(deadline: .now() + accumulatedDelay) { [weak self] in
                guard let self = self, self.isGameModeActive else { return }
                self.activeEphemeralPointerIds.insert(tempPid)
                self.injectTouch(action: .down, pointerId: tempPid, normPos: pos)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + accumulatedDelay + 0.03) { [weak self] in
                guard let self = self, self.isGameModeActive else { return }
                self.injectTouch(action: .up, pointerId: tempPid, normPos: pos)
                self.activeEphemeralPointerIds.remove(tempPid)
            }
        }
    }

    private func processDrag(node: KeyMapNodeConfig) {
        guard let start = node.startPos, let end = node.endPos else { return }
        let dragPid = dragPointerId
        let startPos = CGPoint(x: start.x, y: start.y)
        let endPos = CGPoint(x: end.x, y: end.y)

        let initialDelay = Double(max(0, node.startDelay ?? 0)) / 1000.0
        let steps = 12
        let stepInterval = max(0.01, 0.15 / Double(steps))

        isDragActive = true
        lastDragEndPos = endPos

        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            guard let self = self, self.isGameModeActive else { return }
            self.injectTouch(action: .down, pointerId: dragPid, normPos: startPos)

            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let intermediate = CGPoint(
                    x: startPos.x + (endPos.x - startPos.x) * t,
                    y: startPos.y + (endPos.y - startPos.y) * t
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + stepInterval * Double(i)) { [weak self] in
                    guard let self = self, self.isGameModeActive else { return }
                    self.injectTouch(action: .move, pointerId: dragPid, normPos: intermediate)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + stepInterval * Double(steps + 1)) { [weak self] in
                guard let self = self, self.isGameModeActive else { return }
                self.injectTouch(action: .up, pointerId: dragPid, normPos: endPos)
                self.isDragActive = false
            }
        }
    }

    // MARK: - Pointer ID Allocation & Touch Injection

    private func allocatePointerId(for trigger: InputTrigger) -> UInt64 {
        if let existing = activePointerIds[trigger] {
            return existing
        }
        let inUse = Set(activePointerIds.values)
        // Find an unused pointer ID in range 10...30
        for _ in 10...30 {
            let candidate = nextDynamicPointerId
            nextDynamicPointerId += 1
            if nextDynamicPointerId > 30 {
                nextDynamicPointerId = 10
            }
            if !inUse.contains(candidate) {
                activePointerIds[trigger] = candidate
                return candidate
            }
        }
        let fallback = nextDynamicPointerId
        activePointerIds[trigger] = fallback
        return fallback
    }

    private func freePointerId(for trigger: InputTrigger) {
        activePointerIds.removeValue(forKey: trigger)
    }

    private func releaseAllTouches() {
        stopMouseLookTouch()

        if isSteerTouching {
            injectTouch(action: .up, pointerId: steerWheelPointerId, normPos: currentSteerPos)
            isSteerTouching = false
            isSteerUpPressed = false
            isSteerDownPressed = false
            isSteerLeftPressed = false
            isSteerRightPressed = false
        }

        for (trigger, pid) in activePointerIds {
            if let node = clickNodesMap[trigger], let pos = node.pos {
                injectTouch(action: .up, pointerId: pid, normPos: CGPoint(x: pos.x, y: pos.y))
            }
        }
        activePointerIds.removeAll()

        // Clean up any in-flight ephemeral taps (clickTwice: 35...39, multiClick: 40...49)
        for pid in activeEphemeralPointerIds {
            injectTouch(action: .up, pointerId: pid, normPos: .zero)
        }
        activeEphemeralPointerIds.removeAll()

        if isDragActive {
            injectTouch(action: .up, pointerId: dragPointerId, normPos: lastDragEndPos)
            isDragActive = false
        }

        lastSentMovePositions.removeAll()
    }

    private func injectTouch(action: ControlMessage.TouchAction, pointerId: UInt64, normPos: CGPoint) {
        guard let ic = inputController else { return }
        let devW = ic.deviceSize.width
        let devH = ic.deviceSize.height
        guard devW > 0 && devH > 0 else { return }

        let safeX = (normPos.x.isNaN || normPos.x.isInfinite) ? 0.0 : normPos.x
        let safeY = (normPos.y.isNaN || normPos.y.isInfinite) ? 0.0 : normPos.y
        let clampedX = max(0.0, min(1.0, safeX))
        let clampedY = max(0.0, min(1.0, safeY))

        let androidX = Int32(round(clampedX * Double(devW)))
        let androidY = Int32(round(clampedY * Double(devH)))

        // Filter redundant move packets if integer device coordinates are unchanged
        if action == .move {
            if let last = lastSentMovePositions[pointerId], last.x == androidX && last.y == androidY {
                return
            }
            lastSentMovePositions[pointerId] = (androidX, androidY)
        } else {
            lastSentMovePositions[pointerId] = (androidX, androidY)
        }

        let safeW = UInt16(clamping: max(0, Int(devW)))
        let safeH = UInt16(clamping: max(0, Int(devH)))
        let pt = ControlMessage.Point(x: androidX, y: androidY)
        let res = ControlMessage.Size(width: safeW, height: safeH)

        ic.sendControlMessage(.injectTouch(action: action, pointerId: pointerId, position: pt, resolution: res))
    }
}
