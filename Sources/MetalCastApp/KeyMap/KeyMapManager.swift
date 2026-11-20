import Foundation

public struct KeyMapPreset: Identifiable, Hashable, Sendable {
    public var id: String { fileName }
    public let fileName: String
    public let displayName: String
    public let filePath: String

    public init(fileName: String, displayName: String, filePath: String) {
        self.fileName = fileName
        self.displayName = displayName
        self.filePath = filePath
    }
}

@MainActor
public final class KeyMapManager: ObservableObject {
    public static let shared = KeyMapManager()

    @Published public var availablePresets: [KeyMapPreset] = []
    @Published public var selectedPresetId: String = "gameforpeace.json"

    private var profileCache: [String: KeyMapProfile] = [:]

    private init() {
        refreshPresets()
    }

    public var activePreset: KeyMapPreset? {
        guard !selectedPresetId.isEmpty && selectedPresetId != "none" else { return nil }
        return availablePresets.first(where: { $0.id == selectedPresetId })
    }

    public var activeProfile: KeyMapProfile? {
        guard let preset = activePreset else { return nil }
        return loadProfile(from: preset.filePath)
    }

    public func refreshPresets() {
        var presets: [KeyMapPreset] = []
        var seenFileNames = Set<String>()

        let searchDirs = resolveSearchDirectories()

        for dir in searchDirs {
            guard FileManager.default.fileExists(atPath: dir) else { continue }
            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: dir)
                for file in files where file.hasSuffix(".json") {
                    guard !seenFileNames.contains(file) else { continue }
                    seenFileNames.insert(file)

                    let fullPath = (dir as NSString).appendingPathComponent(file)
                    let displayName = friendlyName(for: file)
                    presets.append(KeyMapPreset(fileName: file, displayName: displayName, filePath: fullPath))
                }
            } catch {
                print("⚠️ [KeyMapManager] 读取目录失败 \(dir): \(error.localizedDescription)")
            }
        }

        presets.sort { $0.displayName < $1.displayName }
        self.availablePresets = presets
    }

    public func loadProfile(from path: String) -> KeyMapProfile? {
        if let cached = profileCache[path] {
            return cached
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            let profile = try decoder.decode(KeyMapProfile.self, from: data)
            profileCache[path] = profile
            print("🎮 [KeyMapManager] 成功加载按键映射配置: \(path)")
            return profile
        } catch {
            print("❌ [KeyMapManager] 解析配置失败 \(path): \(error)")
            return nil
        }
    }

    private func friendlyName(for fileName: String) -> String {
        switch fileName.lowercased() {
        case "gameforpeace.json":
            return "和平精英 / PUBG Mobile"
        case "tiktok.json":
            return "抖音 / TikTok 短视频 (滑动/点赞)"
        case "identityv.json":
            return "第五人格 / Identity V"
        case "frag.json":
            return "FRAG Pro Shooter 射击"
        case "test.json":
            return "按键调试预设 (测试多点/拖拽)"
        default:
            return (fileName as NSString).deletingPathExtension
        }
    }

    private func resolveSearchDirectories() -> [String] {
        var dirs: [String] = []

        // 1. User Application Support folder: ~/Library/Application Support/MetalCast/keymap
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let userKeymapDir = appSupport.appendingPathComponent("MetalCast/keymap").path
            if !FileManager.default.fileExists(atPath: userKeymapDir) {
                try? FileManager.default.createDirectory(atPath: userKeymapDir, withIntermediateDirectories: true)
            }
            dirs.append(userKeymapDir)
        }

        // 2. Main App Bundle Resources
        if let resPath = Bundle.main.resourcePath {
            dirs.append((resPath as NSString).appendingPathComponent("keymap"))
        }
        let bundleKeymap = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/keymap").path
        dirs.append(bundleKeymap)

        // 3. Development local path
        let sourceRelative = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/keymap").path
        dirs.append(sourceRelative)

        return dirs
    }
}
