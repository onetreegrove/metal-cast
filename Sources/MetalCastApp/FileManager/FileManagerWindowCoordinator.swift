import AppKit
import MetalCastCore

@MainActor
public final class FileManagerWindowCoordinator: ObservableObject {
    public static let shared = FileManagerWindowCoordinator()

    @Published public private(set) var openWindowKeys: Set<String> = []
    @Published public private(set) var activeServiceTaskIds: Set<UUID> = []

    private var controllers: [String: FileManagerWindowController] = [:]
    private var observerTask: Task<Void, Never>?

    private init() {
        observerTask = Task { [weak self] in
            let stream = await ADBFileService.shared.events
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                if case .taskUpdated(let snap) = event {
                    if [.queued, .transferring, .committing].contains(snap.state) {
                        self.activeServiceTaskIds.insert(snap.id)
                    } else {
                        self.activeServiceTaskIds.remove(snap.id)
                    }
                }
            }
        }
    }

    deinit {
        observerTask?.cancel()
    }

    public func isWindowOpen(for device: ADBDevice) -> Bool {
        if openWindowKeys.contains(device.selectionKey) {
            return true
        }
        return controllers.values.contains { $0.viewModel.boundDevice.serial == device.serial }
    }

    public var hasActiveWork: Bool {
        !activeServiceTaskIds.isEmpty || controllers.values.contains { $0.viewModel.hasActiveOrCommittingWork }
    }

    public func openOrFocus(device: ADBDevice) {
        guard device.state == .device, device.transportId != nil else { return }
        let key = device.selectionKey

        if let existing = controllers[key] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Enforce single window per physical device even if transport_id changed while previous window stayed open.
        if let existingSameSerial = controllers.values.first(where: { $0.viewModel.boundDevice.serial == device.serial }) {
            let oldKey = existingSameSerial.viewModel.bindingKey
            rebindWindowKey(from: oldKey, to: key)
            existingSameSerial.viewModel.updateReboundDevice(device)
            existingSameSerial.showWindow(nil)
            existingSameSerial.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = FileManagerViewModel(device: device, bindingKey: key, fileService: .shared)
        viewModel.onBindingKeyChanged = { [weak self] oldKey, newKey in
            self?.rebindWindowKey(from: oldKey, to: newKey)
        }
        let controller = FileManagerWindowController(viewModel: viewModel) { [weak self] closedKey in
            self?.controllers.removeValue(forKey: closedKey)
            self?.openWindowKeys.remove(closedKey)
        }
        controllers[key] = controller
        openWindowKeys.insert(key)

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            await viewModel.openInitialSession()
        }
    }

    private func rebindWindowKey(from oldKey: String, to newKey: String) {
        guard oldKey != newKey, let controller = controllers.removeValue(forKey: oldKey) else { return }
        openWindowKeys.remove(oldKey)
        controllers[newKey] = controller
        openWindowKeys.insert(newKey)
    }
}
