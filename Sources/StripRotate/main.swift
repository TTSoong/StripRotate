import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import QuartzCore
import ScreenCaptureKit
import ServiceManagement
#if canImport(PrivateDisplay)
import PrivateDisplay
#endif

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

private struct DisplayCandidate {
    let screen: NSScreen
    let id: CGDirectDisplayID
    let width: Int
    let height: Int
    let key: String

    var title: String {
        "\(screen.localizedName) — \(width)×\(height)"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var targetScreen: NSScreen?
    private var virtualDisplay: CGVirtualDisplay?
    private var captureStream: SCStream?
    private var outputWindow: NSWindow?
    private var outputLayer: AVSampleBufferDisplayLayer?
    private var clockwise = true
    private var running = false
    private var starting = false
    private var shouldRun = true
    private var recoveryWorkItem: DispatchWorkItem?
    private var layoutSaveWorkItem: DispatchWorkItem?
    private var watchdogTimer: Timer?
    private var cursorTimer: Timer?
    private var outputKeeperTimer: Timer?
    private var cursorGuardEnabled = true
    private var lastSafeCursorPosition: CGPoint?
    private var sessionActive = true
    private var recoveryPendingAfterUnlock = false
    private var wakeRecoveryWorkItem: DispatchWorkItem?
    private var lastFrameTimestamp: TimeInterval = 0
    private var firstFrameDeadline: TimeInterval?
    private var selectedTargetKey: String?
    private var targetWidth = 0
    private var targetHeight = 0
    private var virtualWidth = 0
    private var virtualHeight = 0

    private lazy var statusMenuItem = NSMenuItem(title: "尚未啟動", action: nil, keyEquivalent: "")
    private lazy var startStopMenuItem = NSMenuItem(
        title: "開始旋轉輸出",
        action: #selector(toggleRunning),
        keyEquivalent: "r"
    )
    private lazy var directionMenuItem = NSMenuItem(
        title: "切換旋轉方向",
        action: #selector(toggleDirection),
        keyEquivalent: "d"
    )
    private lazy var cursorGuardMenuItem = NSMenuItem(
        title: "阻擋游標進入實體輸出螢幕",
        action: #selector(toggleCursorGuard),
        keyEquivalent: ""
    )
    private lazy var loginItemMenuItem = NSMenuItem(
        title: "登入時自動啟動",
        action: #selector(toggleLoginItem),
        keyEquivalent: ""
    )
    private lazy var targetSelectionMenu = NSMenu(title: "輸出螢幕")
    private lazy var targetSelectionMenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "輸出螢幕", action: nil, keyEquivalent: "")
        item.submenu = targetSelectionMenu
        return item
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reassertOutputAfterSystemTransition),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(sessionDidResignActive),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionDidBecomeActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "cursorGuardEnabled") == nil {
            defaults.set(true, forKey: "cursorGuardEnabled")
        }
        cursorGuardEnabled = defaults.bool(forKey: "cursorGuardEnabled")
        selectedTargetKey = defaults.string(forKey: "selectedTargetKey")
        updatePreferenceMenuStates()
        updateTargetSelectionMenu()
        startMonitoring()
        start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveCurrentLayout()
        stop()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.portrait.rotate", accessibilityDescription: "Strip Rotate")
            button.toolTip = "Strip Rotate"
        }

        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(targetSelectionMenuItem)
        menu.addItem(.separator())

        startStopMenuItem.target = self
        directionMenuItem.target = self
        cursorGuardMenuItem.target = self
        loginItemMenuItem.target = self
        menu.addItem(startStopMenuItem)
        menu.addItem(directionMenuItem)
        menu.addItem(cursorGuardMenuItem)
        menu.addItem(.separator())
        menu.addItem(loginItemMenuItem)

        let settingsItem = NSMenuItem(
            title: "打開顯示器排列…",
            action: #selector(openDisplaySettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "結束 Strip Rotate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    @objc private func toggleRunning() {
        (running || starting) ? stop() : start()
    }

    @objc private func toggleDirection() {
        clockwise.toggle()
        updateLayerGeometry()
        statusMenuItem.title = clockwise ? "運作中：順時針 90°" : "運作中：逆時針 90°"
    }

    @objc private func toggleCursorGuard() {
        cursorGuardEnabled.toggle()
        lastSafeCursorPosition = nil
        UserDefaults.standard.set(cursorGuardEnabled, forKey: "cursorGuardEnabled")
        updatePreferenceMenuStates()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            updatePreferenceMenuStates()
        } catch {
            showError("無法更新登入項目：\(error.localizedDescription)\n\n請先把 Strip Rotate.app 放進「應用程式」資料夾後再試。")
        }
    }

    private func updatePreferenceMenuStates() {
        cursorGuardMenuItem.state = cursorGuardEnabled ? .on : .off
        loginItemMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func displayCandidates() -> [DisplayCandidate] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID, id != CGMainDisplayID() else { return nil }
            if let virtualID = virtualDisplay?.displayID, id == virtualID { return nil }
            let width = CGDisplayPixelsWide(id)
            let height = CGDisplayPixelsHigh(id)
            guard height > width else { return nil }
            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            let serial = CGDisplaySerialNumber(id)
            let unit = CGDisplayUnitNumber(id)
            let key = "\(vendor)-\(model)-\(serial)-\(unit)-\(width)x\(height)"
            return DisplayCandidate(
                screen: screen,
                id: id,
                width: width,
                height: height,
                key: key
            )
        }
        .sorted {
            let leftRatio = Double($0.height) / Double($0.width)
            let rightRatio = Double($1.height) / Double($1.width)
            return leftRatio == rightRatio ? $0.title < $1.title : leftRatio > rightRatio
        }
    }

    private func updateTargetSelectionMenu() {
        targetSelectionMenu.removeAllItems()
        let candidates = displayCandidates()
        guard !candidates.isEmpty else {
            let item = NSMenuItem(title: "找不到直向外接螢幕", action: nil, keyEquivalent: "")
            item.isEnabled = false
            targetSelectionMenu.addItem(item)
            return
        }

        for candidate in candidates {
            let item = NSMenuItem(
                title: candidate.title,
                action: #selector(selectTargetDisplay(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = candidate.key
            item.state = candidate.key == selectedTargetKey ? .on : .off
            targetSelectionMenu.addItem(item)
        }
    }

    @objc private func selectTargetDisplay(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, key != selectedTargetKey else { return }
        let wasActive = running || starting
        saveCurrentLayout()
        selectedTargetKey = key
        UserDefaults.standard.set(key, forKey: "selectedTargetKey")
        updateTargetSelectionMenu()
        if wasActive {
            stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.start()
            }
        }
    }

    @objc private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func screenParametersChanged() {
        updateTargetSelectionMenu()
        guard running, sessionActive else { return }
        if let screen = findTargetScreen() {
            targetScreen = screen
            positionOutputWindow(on: screen)
            scheduleLayoutSave()
        } else {
            statusMenuItem.title = "找不到選定的直向螢幕"
            scheduleRecovery(reason: "等待實體螢幕重新連接…")
        }
    }

    @objc private func reassertOutputAfterSystemTransition() {
        guard running, sessionActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.running, self.sessionActive, let screen = self.findTargetScreen() else { return }
            self.targetScreen = screen
            self.positionOutputWindow(on: screen)
        }
    }

    @objc private func sessionDidResignActive() {
        NSLog("Strip Rotate: session became inactive")
        sessionActive = false
        recoveryPendingAfterUnlock = shouldRun
        wakeRecoveryWorkItem?.cancel()
        wakeRecoveryWorkItem = nil
        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        firstFrameDeadline = nil
        outputWindow?.orderOut(nil)
    }

    @objc private func sessionDidBecomeActive() {
        NSLog("Strip Rotate: session became active")
        sessionActive = true
        wakeRecoveryWorkItem?.cancel()
        wakeRecoveryWorkItem = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.shouldRun, self.sessionActive else { return }
            let virtualDisplayOnline = self.virtualDisplay.map {
                CGDisplayIsOnline($0.displayID) != 0
            } ?? false
            let healthy = self.running
                && virtualDisplayOnline
                && self.captureStream != nil
                && self.findTargetScreen() != nil
            if self.recoveryPendingAfterUnlock || !healthy {
                self.recoveryPendingAfterUnlock = false
                self.scheduleRecovery(reason: "登入完成，正在恢復顯示…")
            } else {
                self.reassertOutputAfterSystemTransition()
            }
        }
    }

    @objc private func systemDidWake() {
        NSLog("Strip Rotate: system or screens woke")
        recoveryPendingAfterUnlock = shouldRun
        scheduleUnlockCheck(attempt: 0)
    }

    private func scheduleUnlockCheck(attempt: Int) {
        wakeRecoveryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRun else { return }
            if self.isSessionLocked(), attempt < 60 {
                self.scheduleUnlockCheck(attempt: attempt + 1)
            } else {
                self.sessionDidBecomeActive()
            }
        }
        wakeRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    private func isSessionLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = session["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    private func start() {
        guard !running, !starting else { return }
        shouldRun = true
        starting = true
        recoveryWorkItem?.cancel()
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        guard let screen = findTargetScreen() else {
            starting = false
            showError("找不到直向的外接螢幕。請確認長條螢幕已連接；若有多台，請從選單列的「輸出螢幕」選擇。")
            return
        }

        targetScreen = screen
        configureDimensions(for: screen)
        statusMenuItem.title = "正在建立虛擬螢幕…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            var displayCreated = false
            for attempt in 0..<5 {
                guard self.starting, self.shouldRun, self.sessionActive else { return }
                if self.createVirtualDisplay(identityOffset: attempt) {
                    displayCreated = true
                    break
                }
                if attempt < 4 {
                    self.statusMenuItem.title = "虛擬螢幕未就緒，重試 \(attempt + 2)/5…"
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }

            guard displayCreated else {
                self.starting = false
                self.stop()
                self.showError("無法建立 \(self.virtualWidth)×\(self.virtualHeight) 虛擬螢幕，已自動重試 5 次。請重新啟動 Mac 後再試。")
                return
            }

            guard let currentScreen = self.findTargetScreen() else {
                self.starting = false
                self.stop()
                self.showError("建立虛擬螢幕後找不到原本選定的實體輸出螢幕。")
                return
            }
            self.targetScreen = currentScreen
            self.createOutputWindow(on: currentScreen)
            self.statusMenuItem.title = "正在啟動畫面擷取…"
            if await self.startDisplayStream() {
                self.starting = false
                self.running = true
                self.statusMenuItem.title = self.clockwise ? "運作中：順時針 90°" : "運作中：逆時針 90°"
                self.startStopMenuItem.title = "停止旋轉輸出"
                self.restoreSavedLayout()
                self.reassertOutputAfterSystemTransition()
                self.scheduleLayoutSave(delay: 3)
                self.showReadyInstructionsIfNeeded()
            } else {
                self.starting = false
                self.stop()
                self.showError("無法讀取虛擬螢幕畫面。請到「隱私權與安全性 → 螢幕與系統錄音」允許 Strip Rotate，然後重新開啟 App。")
            }
        }
    }

    private func stop() {
        shouldRun = false
        recoveryPendingAfterUnlock = false
        wakeRecoveryWorkItem?.cancel()
        wakeRecoveryWorkItem = nil
        recoveryWorkItem?.cancel()
        layoutSaveWorkItem?.cancel()
        tearDownDisplayResources()
        statusMenuItem.title = "已停止"
        startStopMenuItem.title = "開始旋轉輸出"
    }

    private func tearDownDisplayResources() {
        let stream = captureStream
        captureStream = nil
        Task {
            try? await stream?.stopCapture()
        }
        outputWindow?.orderOut(nil)
        outputWindow = nil
        outputLayer = nil
        virtualDisplay = nil
        targetScreen = nil
        lastFrameTimestamp = 0
        firstFrameDeadline = nil
        running = false
        starting = false
    }

    private func findTargetScreen() -> NSScreen? {
        let candidates = displayCandidates()
        if let selectedTargetKey {
            return candidates.first { $0.key == selectedTargetKey }?.screen
        }
        guard let candidate = candidates.first else { return nil }
        selectedTargetKey = candidate.key
        UserDefaults.standard.set(candidate.key, forKey: "selectedTargetKey")
        updateTargetSelectionMenu()
        return candidate.screen
    }

    private func configureDimensions(for screen: NSScreen) {
        guard let id = screen.displayID else { return }
        targetWidth = CGDisplayPixelsWide(id)
        targetHeight = CGDisplayPixelsHigh(id)
        virtualWidth = targetHeight
        virtualHeight = targetWidth
    }

    private func createVirtualDisplay(identityOffset: Int = 0) -> Bool {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.global(qos: .userInitiated))
        descriptor.name = "Strip Rotate \(virtualWidth)x\(virtualHeight)"
        descriptor.maxPixelsWide = UInt32(virtualWidth)
        descriptor.maxPixelsHigh = UInt32(virtualHeight)
        descriptor.sizeInMillimeters = CGSize(
            width: 25.4 * Double(virtualWidth) / 100,
            height: 25.4 * Double(virtualHeight) / 100
        )
        let identity = UInt32(identityOffset)
        descriptor.productID = 0x4501 + identity
        descriptor.vendorID = 0x5352
        descriptor.serialNum = 0x0001 + identity
        descriptor.serialNumber = 0x0001 + identity
        descriptor.redPrimary = CGPoint(x: 0.6797, y: 0.3203)
        descriptor.greenPrimary = CGPoint(x: 0.2559, y: 0.6983)
        descriptor.bluePrimary = CGPoint(x: 0.1494, y: 0.0557)
        descriptor.whitePoint = CGPoint(x: 0.3125, y: 0.3291)
        descriptor.terminationHandler = { [weak self] _, terminatedDisplay in
            DispatchQueue.main.async {
                guard self?.virtualDisplay === terminatedDisplay else { return }
                self?.scheduleRecovery(reason: "虛擬螢幕已中斷，正在恢復…")
            }
        }

        let display = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.rotation = 0
        settings.modes = [
            CGVirtualDisplayMode(
                width: UInt(virtualWidth),
                height: UInt(virtualHeight),
                refreshRate: 60
            )
        ]

        guard display.apply(settings) else { return false }
        virtualDisplay = display
        return true
    }

    private func createOutputWindow(on screen: NSScreen) {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.backgroundColor = .black
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.canHide = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.hasShadow = false

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let imageLayer = AVSampleBufferDisplayLayer()
        imageLayer.videoGravity = .resizeAspect
        view.layer?.addSublayer(imageLayer)
        window.contentView = view

        outputWindow = window
        outputLayer = imageLayer
        updateLayerGeometry()
        positionOutputWindow(on: screen)
        window.orderFrontRegardless()
    }

    private func positionOutputWindow(on screen: NSScreen) {
        outputWindow?.setFrame(screen.frame, display: true)
        outputWindow?.orderFrontRegardless()
        updateLayerGeometry()
    }

    private func updateLayerGeometry() {
        guard let layer = outputLayer, let view = outputWindow?.contentView else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(x: 0, y: 0, width: virtualWidth, height: virtualHeight)
        layer.position = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        layer.setAffineTransform(CGAffineTransform(rotationAngle: clockwise ? .pi / 2 : -.pi / 2))
        CATransaction.commit()
    }

    private func startMonitoring() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.performHealthCheck()
        }
        if let watchdogTimer {
            RunLoop.main.add(watchdogTimer, forMode: .common)
        }

        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.redirectCursorIfNeeded()
        }
        if let cursorTimer {
            RunLoop.main.add(cursorTimer, forMode: .common)
        }

        outputKeeperTimer?.invalidate()
        outputKeeperTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.keepOutputWindowVisible()
        }
        if let outputKeeperTimer {
            RunLoop.main.add(outputKeeperTimer, forMode: .common)
        }
    }

    private func keepOutputWindowVisible() {
        guard running, sessionActive, let window = outputWindow else { return }
        window.canHide = false
        window.hidesOnDeactivate = false
        if !window.isVisible {
            window.setIsVisible(true)
        }
        window.orderFrontRegardless()
    }

    private func performHealthCheck() {
        updatePreferenceMenuStates()
        guard shouldRun, running, sessionActive else { return }
        if let deadline = firstFrameDeadline,
           Date.timeIntervalSinceReferenceDate > deadline {
            NSLog("Strip Rotate: no frames arrived before the recovery deadline")
            firstFrameDeadline = nil
            scheduleRecovery(reason: "未收到畫面，正在重新啟動串流…")
            return
        }
        guard
            let display = virtualDisplay,
            CGDisplayIsOnline(display.displayID) != 0,
            captureStream != nil,
            let screen = findTargetScreen()
        else {
            scheduleRecovery(reason: "顯示連線中斷，正在恢復…")
            return
        }
        targetScreen = screen
        if outputWindow?.isVisible == true {
            outputWindow?.orderFrontRegardless()
        } else {
            positionOutputWindow(on: screen)
        }
    }

    private func scheduleRecovery(reason: String) {
        guard shouldRun else { return }
        guard sessionActive else {
            recoveryPendingAfterUnlock = true
            return
        }
        guard recoveryWorkItem == nil else { return }
        statusMenuItem.title = reason
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.recoveryWorkItem = nil
            guard self.shouldRun else { return }
            self.tearDownDisplayResources()
            self.start()
        }
        recoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    private func scheduleLayoutSave(delay: TimeInterval = 1.5) {
        layoutSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.saveCurrentLayout()
        }
        layoutSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func saveCurrentLayout() {
        guard
            running,
            let virtualID = virtualDisplay?.displayID,
            CGDisplayIsOnline(virtualID) != 0,
            let targetID = findTargetScreen()?.displayID
        else { return }

        let virtualBounds = CGDisplayBounds(virtualID)
        let targetBounds = CGDisplayBounds(targetID)
        let defaults = UserDefaults.standard
        defaults.set(Double(virtualBounds.origin.x), forKey: layoutKey("virtualOriginX"))
        defaults.set(Double(virtualBounds.origin.y), forKey: layoutKey("virtualOriginY"))
        defaults.set(Double(targetBounds.origin.x), forKey: layoutKey("targetOriginX"))
        defaults.set(Double(targetBounds.origin.y), forKey: layoutKey("targetOriginY"))
        defaults.set(true, forKey: layoutKey("hasSavedLayout"))
    }

    private func restoreSavedLayout() {
        let defaults = UserDefaults.standard
        let hasTargetLayout = defaults.bool(forKey: layoutKey("hasSavedLayout"))
        let useLegacyLayout = !hasTargetLayout && defaults.bool(forKey: "hasSavedLayout")
        guard
            hasTargetLayout || useLegacyLayout,
            let virtualID = virtualDisplay?.displayID,
            let targetID = findTargetScreen()?.displayID
        else { return }

        let prefix: (String) -> String = { [weak self] name in
            useLegacyLayout ? name : (self?.layoutKey(name) ?? name)
        }
        let virtualX = Int32(defaults.double(forKey: prefix("virtualOriginX")))
        let virtualY = Int32(defaults.double(forKey: prefix("virtualOriginY")))
        let targetX = Int32(defaults.double(forKey: prefix("targetOriginX")))
        let targetY = Int32(defaults.double(forKey: prefix("targetOriginY")))

        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else { return }
        guard CGConfigureDisplayOrigin(configuration, virtualID, virtualX, virtualY) == .success,
              CGConfigureDisplayOrigin(configuration, targetID, targetX, targetY) == .success
        else {
            CGCancelDisplayConfiguration(configuration)
            return
        }
        _ = CGCompleteDisplayConfiguration(configuration, .forSession)
    }

    private func layoutKey(_ name: String) -> String {
        "layout.\(selectedTargetKey ?? "default").\(name)"
    }

    private func redirectCursorIfNeeded() {
        guard
            cursorGuardEnabled,
            running,
            sessionActive,
            let targetID = targetScreen?.displayID,
            let event = CGEvent(source: nil)
        else { return }

        let targetBounds = CGDisplayBounds(targetID)
        let point = event.location
        guard targetBounds.contains(point) else {
            lastSafeCursorPosition = point
            return
        }

        if let lastSafeCursorPosition {
            CGWarpMouseCursorPosition(lastSafeCursorPosition)
        }
    }

    @MainActor
    private func startDisplayStream() async -> Bool {
        guard let display = virtualDisplay else { return false }
        do {
            var shareableDisplay: SCDisplay?
            for _ in 0..<15 {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                shareableDisplay = content.displays.first { $0.displayID == display.displayID }
                if shareableDisplay != nil { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }

            guard let shareableDisplay else { return false }
            let filter = SCContentFilter(
                display: shareableDisplay,
                excludingApplications: [],
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.width = virtualWidth
            configuration.height = virtualHeight
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 5
            configuration.showsCursor = true
            configuration.pixelFormat = kCVPixelFormatType_32BGRA

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "tw.kayinsoong.StripRotate.frames", qos: .userInteractive)
            )
            try await stream.startCapture()
            captureStream = stream
            lastFrameTimestamp = 0
            firstFrameDeadline = Date.timeIntervalSinceReferenceDate + 10
            return true
        } catch {
            NSLog("Strip Rotate capture error: %@", String(describing: error))
            return false
        }
    }

    private func showError(_ message: String) {
        statusMenuItem.title = "啟動失敗"
        let alert = NSAlert()
        alert.messageText = "Strip Rotate"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showReadyInstructionsIfNeeded() {
        let key = "didShowReadyInstructions"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.messageText = "旋轉輸出已啟動"
        alert.informativeText = "請在「顯示器排列」中，把 Strip Rotate \(virtualWidth)x\(virtualHeight) 放在主螢幕旁邊，並把 \(targetWidth)x\(targetHeight) 實體螢幕移到較遠處。之後將視窗拖到 Strip Rotate 虛擬螢幕即可。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打開顯示器排列")
        alert.addButton(withTitle: "稍後")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openDisplaySettings()
        }
    }
}

extension AppDelegate: SCStreamOutput, SCStreamDelegate {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.captureStream === stream else { return }
            self.lastFrameTimestamp = Date.timeIntervalSinceReferenceDate
            self.firstFrameDeadline = nil
            guard let layer = self.outputLayer else { return }
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
            }
            renderer.enqueue(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            NSLog("Strip Rotate stream stopped: %@", String(describing: error))
            self.scheduleRecovery(reason: "串流已停止，正在重新啟動…")
        }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
