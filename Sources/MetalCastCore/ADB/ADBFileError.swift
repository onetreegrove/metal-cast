import Foundation

public enum ADBFileError: LocalizedError, Sendable, Equatable {
    case incompatibleEndpoint(String)
    case adbServerStartFailed(String)
    case sessionInvalidated
    case unsupportedDevice(String)
    case restrictedPath(String)
    case invalidFileName(String)
    case pathTooLong(Int)
    case pathChanged(String)
    case permissionDenied(String)
    case targetChanged(String)
    case diskFull(String)
    case protocolError(stage: String, detail: String)
    case operationUnconfirmed(String)

    public var errorDescription: String? {
        switch self {
        case .incompatibleEndpoint(let detail):
            return "ADB 端点配置不兼容: \(detail)"
        case .adbServerStartFailed(let detail):
            return "启动本地 ADB Server 失败: \(detail)"
        case .sessionInvalidated:
            return "设备会话已失效，请重新连接并核对设备"
        case .unsupportedDevice(let detail):
            return "当前设备不支持所需协议: \(detail)"
        case .restrictedPath(let path):
            return "首版不支持访问受限路径: \(path)"
        case .invalidFileName(let detail):
            return "文件名不合规: \(detail)"
        case .pathTooLong(let length):
            return "路径长度（\(length) 字节）超过限制"
        case .pathChanged(let detail):
            return "目标目录物理路径发生变化: \(detail)"
        case .permissionDenied(let detail):
            return "无权限访问目标路径: \(detail)"
        case .targetChanged(let detail):
            return "目标文件在操作前发生变更: \(detail)"
        case .diskFull(let detail):
            return "存储空间不足: \(detail)"
        case .protocolError(let stage, let detail):
            return "ADB 协议错误 [\(stage)]: \(detail)"
        case .operationUnconfirmed(let detail):
            return "操作状态未获确认: \(detail)"
        }
    }
}
