import Foundation

public struct KeyMapPosition: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = (x.isNaN || x.isInfinite) ? 0.0 : x
        self.y = (y.isNaN || y.isInfinite) ? 0.0 : y
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawX = try container.decode(Double.self, forKey: .x)
        let rawY = try container.decode(Double.self, forKey: .y)
        self.x = (rawX.isNaN || rawX.isInfinite) ? 0.0 : rawX
        self.y = (rawY.isNaN || rawY.isInfinite) ? 0.0 : rawY
    }
}

public struct DelayClickNode: Codable, Equatable, Sendable {
    public var delay: Int
    public var pos: KeyMapPosition

    public var effectiveDelay: Int {
        return max(0, delay)
    }

    public init(delay: Int, pos: KeyMapPosition) {
        self.delay = delay
        self.pos = pos
    }
}

public struct SmallEyesConfig: Codable, Equatable, Sendable {
    public var comment: String?
    public var type: String?
    public var key: String
    public var pos: KeyMapPosition
    public var switchMap: Bool?

    public init(comment: String? = nil, type: String? = nil, key: String, pos: KeyMapPosition, switchMap: Bool? = nil) {
        self.comment = comment
        self.type = type
        self.key = key
        self.pos = pos
        self.switchMap = switchMap
    }
}

public struct MouseMoveMapConfig: Codable, Equatable, Sendable {
    public var startPos: KeyMapPosition
    public var speedRatioX: Double?
    public var speedRatioY: Double?
    public var speedRatio: Double?
    public var smallEyes: SmallEyesConfig?

    public init(startPos: KeyMapPosition, speedRatioX: Double? = nil, speedRatioY: Double? = nil, speedRatio: Double? = nil, smallEyes: SmallEyesConfig? = nil) {
        self.startPos = startPos
        self.speedRatioX = speedRatioX
        self.speedRatioY = speedRatioY
        self.speedRatio = speedRatio
        self.smallEyes = smallEyes
    }

    public var effectiveSpeedRatioX: Double {
        if let sx = speedRatioX, sx > 0 { return sx }
        if let s = speedRatio, s > 0 { return s }
        return 3.0
    }

    public var effectiveSpeedRatioY: Double {
        if let sy = speedRatioY, sy > 0 { return sy }
        if let s = speedRatio, s > 0 { return s / 2.25 }
        return 1.33
    }
}

public enum KeyNodeType: String, Codable, Sendable {
    case steerWheel = "KMT_STEER_WHEEL"
    case click = "KMT_CLICK"
    case clickTwice = "KMT_CLICK_TWICE"
    case clickMulti = "KMT_CLICK_MULTI"
    case drag = "KMT_DRAG"
    case androidKey = "KMT_ANDROID_KEY"
}

public struct KeyMapNodeConfig: Codable, Equatable, Sendable {
    public var comment: String?
    public var type: KeyNodeType
    public var key: String?

    // KMT_CLICK & KMT_CLICK_TWICE
    public var pos: KeyMapPosition?
    public var switchMap: Bool?
    public var androidKey: Int?

    // KMT_STEER_WHEEL
    public var centerPos: KeyMapPosition?
    public var leftOffset: Double?
    public var rightOffset: Double?
    public var upOffset: Double?
    public var downOffset: Double?
    public var leftKey: String?
    public var rightKey: String?
    public var upKey: String?
    public var downKey: String?

    // KMT_CLICK_MULTI
    public var clickNodes: [DelayClickNode]?

    // KMT_DRAG
    public var startPos: KeyMapPosition?
    public var endPos: KeyMapPosition?
    public var startDelay: Int?
    public var dragSpeed: Double?

    public init(
        comment: String? = nil,
        type: KeyNodeType,
        key: String? = nil,
        pos: KeyMapPosition? = nil,
        switchMap: Bool? = nil,
        androidKey: Int? = nil,
        centerPos: KeyMapPosition? = nil,
        leftOffset: Double? = nil,
        rightOffset: Double? = nil,
        upOffset: Double? = nil,
        downOffset: Double? = nil,
        leftKey: String? = nil,
        rightKey: String? = nil,
        upKey: String? = nil,
        downKey: String? = nil,
        clickNodes: [DelayClickNode]? = nil,
        startPos: KeyMapPosition? = nil,
        endPos: KeyMapPosition? = nil,
        startDelay: Int? = nil,
        dragSpeed: Double? = nil
    ) {
        self.comment = comment
        self.type = type
        self.key = key
        self.pos = pos
        self.switchMap = switchMap
        self.androidKey = androidKey
        self.centerPos = centerPos
        self.leftOffset = leftOffset
        self.rightOffset = rightOffset
        self.upOffset = upOffset
        self.downOffset = downOffset
        self.leftKey = leftKey
        self.rightKey = rightKey
        self.upKey = upKey
        self.downKey = downKey
        self.clickNodes = clickNodes
        self.startPos = startPos
        self.endPos = endPos
        self.startDelay = startDelay
        self.dragSpeed = dragSpeed
    }
}

public struct KeyMapProfile: Codable, Equatable, Sendable {
    public var switchKey: String?
    public var mouseMoveMap: MouseMoveMapConfig?
    public var keyMapNodes: [KeyMapNodeConfig]

    public init(switchKey: String? = nil, mouseMoveMap: MouseMoveMapConfig? = nil, keyMapNodes: [KeyMapNodeConfig] = []) {
        self.switchKey = switchKey
        self.mouseMoveMap = mouseMoveMap
        self.keyMapNodes = keyMapNodes
    }
}
