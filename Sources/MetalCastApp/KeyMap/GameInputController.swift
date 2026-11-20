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
    private var activePointerIds: [InputTrigger: UInt64] = [:]
    private var nextDynamicPointerId: UInt64 = 10

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

    // Mouse Look state
    private var isMouseLookTouching = false
    private var currentMouseLookPos: CGPoint = .zero
    private var mouseLookIdleTimer: Timer?
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
            self.switchTrigger = tr
        } else {
            self.switchTrigger = .key(50) // Default `~`
        }

        // 2. Mouse Move Map
        if let mm = profile.mouseMoveMap {
            self.mouseMoveConfig = mm
            if let se = mm.smallEyes, let seTr = KeyMappingConverter.parseTrigger(from: se.key) {
                self.smallEyesTrigger = seTr
            }
        }

        // 3. Key Map Nodes
        for node in profile.keyMapNodes {
            switch node.type {
            case .steerWheel:
                self.steerWheelNode = node
                if let k = node.upKey { self.steerUpTrigger = KeyMappingConverter.parseTrigger(from: k) }
                if let k = node.downKey { self.steerDownTrigger = KeyMappingConverter.parseTrigger(from: k) }
                if let k = node.leftKey { self.steerLeftTrigger = KeyMappingConverter.parseTrigger(from: k) }
                if let k = node.rightKey { self.steerRightTrigger = KeyMappingConverter.parseTrigger(from: k) }

            case .click, .clickTwice, .androidKey:
                if let k = node.key, let tr = KeyMappingConverter.parseTrigger(from: k) {
                    clickNodesMap[tr] = node
                }

            case .clickMulti:
                if let k = node.key, let tr = KeyMappingConverter.parseTrigger(from: k) {
                    multiClickNodesMap[tr] = node
                }

            case .drag:
                if let k = node.key, let tr = KeyMappingConverter.parseTrigger(from: k) {
                    dragNodesMap[tr] = node
                }
            }
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
        let trigger = InputTrigger.key(event.keyCode)

        // 1. Switch Key toggle
        if trigger == switchTrigger {
            toggleGameMode()
            return true
        }

        // If game mode is not active, let normal input pass through
        guard isGameModeActive else { return false }

        // If pointer is temporarily released (e.g. Map / Inventory open), check if pressed key toggles it back
        if isCursorTemporarilyReleased {
            if let node = clickNodesMap[trigger], node.switchMap == true {
                processKeyClick(trigger: trigger, node: node, isDown: true)
                toggleTemporaryPointerRelease()
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
        let trigger = InputTrigger.key(event.keyCode)

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
        guard profile != nil, isGameModeActive, !isCursorTemporarilyReleased else { return false }
        let trigger = InputTrigger.mouseButton(button)

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
        let dx = Double(deltaX) / (speedX * 600.0)
        let dy = Double(deltaY) / (speedY * 600.0)

        if !isMouseLookTouching {
            currentMouseLookPos = CGPoint(x: baseStartPos.x, y: baseStartPos.y)
            injectTouch(action: .down, pointerId: targetPointerId, normPos: currentMouseLookPos)
            isMouseLookTouching = true
        }

        currentMouseLookPos.x += dx
        currentMouseLookPos.y += dy

        // Boundary Reset (Infinite Pan)
        if currentMouseLookPos.x < 0.08 || currentMouseLookPos.x > 0.92 ||
           currentMouseLookPos.y < 0.08 || currentMouseLookPos.y > 0.92 {
            injectTouch(action: .up, pointerId: targetPointerId, normPos: currentMouseLookPos)
            currentMouseLookPos = CGPoint(x: baseStartPos.x, y: baseStartPos.y)
            injectTouch(action: .down, pointerId: targetPointerId, normPos: currentMouseLookPos)
        } else {
            injectTouch(action: .move, pointerId: targetPointerId, normPos: currentMouseLookPos)
        }

        resetMouseLookIdleTimer(pointerId: targetPointerId)
        return true
    }

    private func resetMouseLookIdleTimer(pointerId: UInt64) {
        mouseLookIdleTimer?.invalidate()
        mouseLookIdleTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopMouseLookTouch()
            }
        }
    }

    private func stopMouseLookTouch() {
        mouseLookIdleTimer?.invalidate()
        mouseLookIdleTimer = nil
        if isMouseLookTouching {
            let pointerId = isSmallEyesActive ? smallEyesPointerId : mouseLookPointerId
            injectTouch(action: .up, pointerId: pointerId, normPos: currentMouseLookPos)
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
            let pid = allocatePointerId(for: trigger)
            injectTouch(action: .down, pointerId: pid, normPos: cgPos)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.injectTouch(action: .up, pointerId: pid, normPos: cgPos)
                self?.freePointerId(for: trigger)
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
            accumulatedDelay += Double(click.delay) / 1000.0
            let pos = CGPoint(x: click.pos.x, y: click.pos.y)
            let tempPid: UInt64 = 40 + UInt64(idx % 10)

            DispatchQueue.main.asyncAfter(deadline: .now() + accumulatedDelay) { [weak self] in
                self?.injectTouch(action: .down, pointerId: tempPid, normPos: pos)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + accumulatedDelay + 0.03) { [weak self] in
                self?.injectTouch(action: .up, pointerId: tempPid, normPos: pos)
            }
        }
    }

    private func processDrag(node: KeyMapNodeConfig) {
        guard let start = node.startPos, let end = node.endPos else { return }
        let dragPid: UInt64 = 55
        let startPos = CGPoint(x: start.x, y: start.y)
        let endPos = CGPoint(x: end.x, y: end.y)

        let initialDelay = Double(node.startDelay ?? 0) / 1000.0
        let steps = 12
        let stepInterval = max(0.01, 0.15 / Double(steps))

        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
            guard let self = self else { return }
            self.injectTouch(action: .down, pointerId: dragPid, normPos: startPos)

            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let intermediate = CGPoint(
                    x: startPos.x + (endPos.x - startPos.x) * t,
                    y: startPos.y + (endPos.y - startPos.y) * t
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + stepInterval * Double(i)) { [weak self] in
                    self?.injectTouch(action: .move, pointerId: dragPid, normPos: intermediate)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + stepInterval * Double(steps + 1)) { [weak self] in
                self?.injectTouch(action: .up, pointerId: dragPid, normPos: endPos)
            }
        }
    }

    // MARK: - Pointer ID Allocation & Touch Injection

    private func allocatePointerId(for trigger: InputTrigger) -> UInt64 {
        if let existing = activePointerIds[trigger] {
            return existing
        }
        let id = nextDynamicPointerId
        nextDynamicPointerId += 1
        if nextDynamicPointerId > 30 {
            nextDynamicPointerId = 10
        }
        activePointerIds[trigger] = id
        return id
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
    }

    private func injectTouch(action: ControlMessage.TouchAction, pointerId: UInt64, normPos: CGPoint) {
        guard let ic = inputController else { return }
        let devW = ic.deviceSize.width
        let devH = ic.deviceSize.height
        guard devW > 0 && devH > 0 else { return }

        let clampedX = max(0.0, min(1.0, normPos.x))
        let clampedY = max(0.0, min(1.0, normPos.y))

        let androidX = Int32(round(clampedX * Double(devW)))
        let androidY = Int32(round(clampedY * Double(devH)))

        let pt = ControlMessage.Point(x: androidX, y: androidY)
        let res = ControlMessage.Size(width: UInt16(devW), height: UInt16(devH))

        ic.connection?.sendControlMessage(.injectTouch(action: action, pointerId: pointerId, position: pt, resolution: res))
    }
}
