import AppKit
import MetalCastCore

public final class InputController: @unchecked Sendable {
    public var deviceSize: CGSize = CGSize(width: 720, height: 1600)
    private weak var connection: ScrcpyConnection?

    public init(connection: ScrcpyConnection? = nil) {
        self.connection = connection
    }

    public func setConnection(_ connection: ScrcpyConnection) {
        self.connection = connection
    }

    /// Converts view point (top-left origin if flipped) to Android coordinates
    public func mapPoint(_ point: CGPoint, in viewSize: CGSize) -> ControlMessage.Point? {
        guard deviceSize.width > 0 && deviceSize.height > 0,
              viewSize.width > 0 && viewSize.height > 0 else { return nil }

        let deviceRatio = deviceSize.width / deviceSize.height
        let viewRatio = viewSize.width / viewSize.height

        var videoWidth = viewSize.width
        var videoHeight = viewSize.height
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0

        if viewRatio > deviceRatio {
            // Pillarbox (black bars on left & right)
            videoWidth = viewSize.height * deviceRatio
            offsetX = (viewSize.width - videoWidth) / 2.0
        } else {
            // Letterbox (black bars on top & bottom)
            videoHeight = viewSize.width / deviceRatio
            offsetY = (viewSize.height - videoHeight) / 2.0
        }

        let relativeX = point.x - offsetX
        let relativeY = point.y - offsetY

        guard relativeX >= 0 && relativeX <= videoWidth &&
              relativeY >= 0 && relativeY <= videoHeight else {
            return nil
        }

        let androidX = Int32((relativeX / videoWidth) * deviceSize.width)
        let androidY = Int32((relativeY / videoHeight) * deviceSize.height)

        return ControlMessage.Point(x: androidX, y: androidY)
    }

    // POINTER_ID_GENERIC_FINGER = -2 in scrcpy
    private let genericFingerId: UInt64 = 0xFFFFFFFFFFFFFFFE

    public func handleMouseDown(at point: CGPoint, in viewSize: CGSize) {
        guard let androidPoint = mapPoint(point, in: viewSize) else { return }
        let res = ControlMessage.Size(width: UInt16(deviceSize.width), height: UInt16(deviceSize.height))
        connection?.sendControlMessage(.injectTouch(action: .down, pointerId: genericFingerId, position: androidPoint, resolution: res))
    }

    public func handleMouseDragged(to point: CGPoint, in viewSize: CGSize) {
        guard let androidPoint = mapPoint(point, in: viewSize) else { return }
        let res = ControlMessage.Size(width: UInt16(deviceSize.width), height: UInt16(deviceSize.height))
        connection?.sendControlMessage(.injectTouch(action: .move, pointerId: genericFingerId, position: androidPoint, resolution: res))
    }

    public func handleMouseUp(at point: CGPoint, in viewSize: CGSize) {
        let androidPoint = mapPoint(point, in: viewSize) ?? ControlMessage.Point(x: 0, y: 0)
        let res = ControlMessage.Size(width: UInt16(deviceSize.width), height: UInt16(deviceSize.height))
        connection?.sendControlMessage(.injectTouch(action: .up, pointerId: genericFingerId, position: androidPoint, resolution: res))
    }

    public func handleScroll(at point: CGPoint, in viewSize: CGSize, deltaX: CGFloat, deltaY: CGFloat) {
        guard let androidPoint = mapPoint(point, in: viewSize) else { return }
        let res = ControlMessage.Size(width: UInt16(deviceSize.width), height: UInt16(deviceSize.height))

        // Normalize [-16, 16] to [-1.0, 1.0] and map to fixed point Int16 [-32768, 32767]
        let hNorm = max(-1.0, min(1.0, Double(-deltaX) / 16.0))
        let vNorm = max(-1.0, min(1.0, Double(-deltaY) / 16.0))
        let hScrollI16 = Int16(clamping: Int(round(hNorm * 32767.0)))
        let vScrollI16 = Int16(clamping: Int(round(vNorm * 32767.0)))

        connection?.sendControlMessage(.injectScroll(position: androidPoint, resolution: res, hScroll: hScrollI16, vScroll: vScrollI16))
    }

    public func sendBack() {
        // Android KEYCODE_BACK = 4
        sendKeycode(4)
    }

    public func sendHome() {
        // Android KEYCODE_HOME = 3
        sendKeycode(3)
    }

    public func sendAppSwitch() {
        // Android KEYCODE_APP_SWITCH = 187
        sendKeycode(187)
    }

    public func sendVolumeUp() {
        // Android KEYCODE_VOLUME_UP = 24
        sendKeycode(24)
    }

    public func sendVolumeDown() {
        // Android KEYCODE_VOLUME_DOWN = 25
        sendKeycode(25)
    }

    public func sendPower() {
        // Android KEYCODE_POWER = 26
        sendKeycode(26)
    }

    public func sendText(_ text: String) {
        connection?.sendControlMessage(.injectText(text: text))
    }

    public func sendKeycode(_ keycode: UInt32, metaState: UInt32 = 0) {
        connection?.sendControlMessage(.injectKeycode(action: .down, keycode: keycode, metaState: metaState))
        connection?.sendControlMessage(.injectKeycode(action: .up, keycode: keycode, metaState: metaState))
    }

    public func setScreenPower(on: Bool) {
        connection?.sendControlMessage(.setScreenPower(on: on))
    }
}
