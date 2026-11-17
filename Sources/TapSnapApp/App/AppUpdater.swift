import AppKit
import Sparkle

/// Sparkle owns download, validation and installation. TapSnap decides when to show its reminders.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private static let lastRemindedBuildKey = "TapSnapLastRemindedUpdateBuild"

    private let isBusy: () -> Bool
    private let notify: (String) -> Void
    private let defaults: UserDefaults
    private var controller: SPUStandardUpdaterController?
    private var pendingUpdate: (build: String, version: String)?
    private var pendingRelaunch: (() -> Void)?
    private var idleWait: Task<Void, Never>?
    private(set) var availableVersion: String? {
        didSet { if oldValue != availableVersion { onAvailabilityChanged?() } }
    }
    var onAvailabilityChanged: (() -> Void)?

    init(isBusy: @escaping () -> Bool, notify: @escaping (String) -> Void, defaults: UserDefaults = .standard) {
        self.isBusy = isBusy
        self.notify = notify
        self.defaults = defaults
    }

    func start() {
        guard controller == nil,
              let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        controller.startUpdater()
    }

    var canCheckForUpdates: Bool { !isBusy() && (controller?.updater.canCheckForUpdates ?? true) }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        guard let controller else {
            notify("当前版本还未配置更新源")
            return
        }
        controller.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate, !state.userInitiated else { return }
        queueReminder(build: update.versionString, version: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { clearReminder() }

    func standardUserDriverWillFinishUpdateSession() {
        pendingRelaunch = nil
        clearReminder()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeRelaunchIfBusy(installHandler)
    }

    func queueReminder(build: String, version: String) {
        pendingUpdate = (build, version)
        deliverWhenIdle()
    }

    func postponeRelaunchIfBusy(_ relaunch: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        pendingRelaunch = relaunch
        deliverWhenIdle()
        return true
    }

    private func clearReminder() {
        pendingUpdate = nil
        availableVersion = nil
        if pendingRelaunch == nil {
            idleWait?.cancel()
            idleWait = nil
        }
    }

    private func deliverWhenIdle() {
        if !isBusy() {
            idleWait?.cancel()
            idleWait = nil
            deliverPendingActions()
            return
        }
        guard idleWait == nil else { return }

        // Only poll while an offered update or confirmed restart is waiting for the capture to finish.
        idleWait = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                if !isBusy() {
                    idleWait = nil
                    deliverPendingActions()
                    return
                }
            }
        }
    }

    private func deliverPendingActions() {
        if let relaunch = pendingRelaunch {
            pendingRelaunch = nil
            clearReminder()
            relaunch()
            return
        }
        guard let update = pendingUpdate else { return }
        pendingUpdate = nil
        availableVersion = update.version
        if defaults.string(forKey: Self.lastRemindedBuildKey) != update.build {
            defaults.set(update.build, forKey: Self.lastRemindedBuildKey)
            notify("TapSnap \(update.version) 可更新，请在菜单栏查看")
        }
    }
}
