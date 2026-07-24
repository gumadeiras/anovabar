import Testing
@testable import AnovaBar

struct ScanButtonStateTests {
    @Test
    @MainActor
    func launchScanRunsOnceAndManualScanUpdatesTitle() async {
        var scanCount = 0
        let model = AppModel { _ in
            scanCount += 1
            return []
        }

        await model.scanOnLaunchIfNeeded()
        await model.scanOnLaunchIfNeeded()

        #expect(scanCount == 1)
        #expect(model.scanButtonTitle == "Scan")

        await model.scan()

        #expect(scanCount == 2)
        #expect(model.scanButtonTitle == "Rescan")
    }

    @Test
    @MainActor
    func cancelledLaunchScanDoesNotPresentError() async {
        let model = AppModel { _ in
            throw CancellationError()
        }

        await model.scanOnLaunchIfNeeded()

        #expect(model.presentedError == nil)
        #expect(model.scanButtonTitle == "Scan")
    }

    @Test
    func automaticEmptyScanKeepsScanTitle() {
        var state = ScanButtonState()

        state.recordCompletedScan(trigger: .automatic, foundDevices: false)

        #expect(state.title(isScanning: false) == "Scan")
    }

    @Test
    func manualEmptyScanShowsRescanTitle() {
        var state = ScanButtonState()

        state.recordCompletedScan(trigger: .manual, foundDevices: false)

        #expect(state.title(isScanning: false) == "Rescan")
    }

    @Test
    func manualSuccessfulScanRestoresScanTitle() {
        var state = ScanButtonState()
        state.recordCompletedScan(trigger: .manual, foundDevices: false)

        state.recordCompletedScan(trigger: .manual, foundDevices: true)

        #expect(state.title(isScanning: false) == "Scan")
    }

    @Test
    func activeScanShowsScanningTitle() {
        var state = ScanButtonState()
        state.recordCompletedScan(trigger: .manual, foundDevices: false)

        #expect(state.title(isScanning: true) == "Scanning…")
    }
}
