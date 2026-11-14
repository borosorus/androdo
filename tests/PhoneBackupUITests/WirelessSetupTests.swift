import Foundation
import XCTest
@testable import PhoneBackupCore
@testable import PhoneBackupUI

@MainActor
final class WirelessSetupTests: XCTestCase {
    func testPairingIsBusyAndDoesNotReadPhoneFolders() async throws {
        let targetID = try DeviceID(value: "wireless-target")
        let remote = FakeDeviceTransport()
        let wireless = TestWirelessADB(connectedDevice: fixtureDevice(id: targetID, model: "Pixel"), pausePairing: true)
        let preferences = AppPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let model = makeModel(remote: remote, wireless: wireless, preferences: preferences)
        let ownerID = UUID()

        model.pairWirelessADB(host: "192.168.1.42", port: "37123", code: "123456", ownerID: ownerID)
        let pairingStarted = await wireless.waitUntilPairingStarts()
        XCTAssertTrue(pairingStarted, "The fake pairing request should start promptly")
        XCTAssertTrue(model.isPairingWireless)
        XCTAssertTrue(model.isBusy)

        model.connectWirelessADB(host: "192.168.1.42", port: "45678", ownerID: ownerID)
        let blockedConnectionCount = await wireless.connectionCount()
        let initialFolderReads = await remote.recordedChildrenCalls(on: targetID)
        XCTAssertEqual(blockedConnectionCount, 0)
        XCTAssertTrue(initialFolderReads.isEmpty)

        let replacementADB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: replacementADB)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacementADB.path)
        defer { try? FileManager.default.removeItem(at: replacementADB) }
        model.locateADB(at: replacementADB)
        XCTAssertNil(model.adbExecutableURL)
        XCTAssertNil(preferences.adbExecutablePath)

        model.cancelWirelessSetupOperation(ownerID: UUID())
        XCTAssertTrue(model.isBusy, "An unrelated setup window cannot cancel this operation")
        model.cancelWirelessSetupOperation(ownerID: ownerID)
        XCTAssertTrue(model.isBusy, "The cancelled command stays serialized until its task exits")
        XCTAssertTrue(model.isCancellingWireless)
        model.connectWirelessADB(host: "192.168.1.42", port: "45678", ownerID: ownerID)
        let connectionCountWhileCancelling = await wireless.connectionCount()
        XCTAssertEqual(connectionCountWhileCancelling, 0)
        await wireless.completePairing()
        await waitUntilIdle(model)

        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isPairingWireless)
        XCTAssertFalse(model.isCancellingWireless)
        XCTAssertTrue(model.wirelessSetupMessage?.contains("cancelled") == true)
        let pairingCount = await wireless.pairingCount()
        let folderReadsAfterPair = await remote.recordedChildrenCalls(on: targetID)
        XCTAssertEqual(pairingCount, 1)
        XCTAssertTrue(folderReadsAfterPair.isEmpty)
    }

    func testWirelessConnectSelectsVerifiedDeviceWithoutRefreshingOrOpeningFolders() async throws {
        let targetID = try DeviceID(value: "paired-wifi-phone")
        let targetSession = DeviceSession.fixture(deviceID: targetID, kind: .wireless)
        let target = AndroidDevice(id: targetID, state: .device, model: "Pixel", sessions: [targetSession])
        let remote = FakeDeviceTransport()
        let wireless = TestWirelessADB(connectedDevice: target)
        let model = makeModel(remote: remote, wireless: wireless)
        let ownerID = UUID()

        await model.refreshDevices()
        XCTAssertEqual(model.statusMessage, "No Android device is connected.")
        model.connectWirelessADB(host: "192.168.1.42", port: "45678", ownerID: ownerID)
        await waitUntilIdle(model)

        XCTAssertEqual(model.selectedDevice?.id, targetID)
        XCTAssertEqual(model.devices.map(\.id), [targetID])
        XCTAssertEqual(model.selectedDevice?.preferredSession?.connection.kind, .wireless)
        XCTAssertTrue(model.wirelessSetupMessage?.contains("Connected over Wi-Fi") == true)
        XCTAssertNil(model.statusMessage)
        let connectionCount = await wireless.connectionCount()
        let targetFolderReads = await remote.recordedChildrenCalls(on: targetID)
        XCTAssertEqual(connectionCount, 1)
        XCTAssertTrue(targetFolderReads.isEmpty)
    }

    func testDelayedDeviceRefreshCannotOverwriteAnActiveWirelessConnection() async throws {
        let existingID = try DeviceID(value: "existing-usb-phone")
        let targetID = try DeviceID(value: "paired-wifi-phone")
        let existing = fixtureDevice(id: existingID, model: "Other Phone")
        let target = AndroidDevice(id: targetID, state: .device, model: "Pixel",
                                   sessions: [DeviceSession.fixture(deviceID: targetID, kind: .wireless)])
        let remote = FakeDeviceTransport(devices: [existing])
        let wireless = TestWirelessADB(connectedDevice: target, pauseConnecting: true)
        let model = makeModel(remote: remote, wireless: wireless)
        let ownerID = UUID()

        await model.refreshDevices()
        XCTAssertEqual(model.selectedDevice?.id, existingID)
        model.connectWirelessADB(host: "192.168.1.42", port: "45678", ownerID: ownerID)
        let connectingStarted = await wireless.waitUntilConnectingStarts()
        XCTAssertTrue(connectingStarted, "The fake connection request should start promptly")
        await remote.setDevices([])
        await model.refreshDevices()

        XCTAssertTrue(model.isConnectingWireless)
        XCTAssertFalse(model.isRefreshingDevices)
        XCTAssertEqual(model.selectedDevice?.id, existingID)

        await wireless.completeConnection()
        await waitUntilIdle(model)
        XCTAssertEqual(model.selectedDevice?.id, targetID)
    }

    private func makeModel(remote: FakeDeviceTransport, wireless: TestWirelessADB,
                           preferences: AppPreferences = AppPreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)) -> AppModel {
        AppModel(services: AppServices(repositoryStore: FakeBackupRepositoryStore(),
                                       deviceTransport: remote, remoteAccess: remote,
                                       remoteDestinationAccess: remote, wirelessADB: wireless),
                 preferences: preferences,
                 loadOnStart: false)
    }

    private func waitUntilIdle(_ model: AppModel) async {
        let finished = expectation(description: "Wireless operation finishes")
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(2)
            while model.isBusy && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            if !model.isBusy { finished.fulfill() }
        }
        await fulfillment(of: [finished], timeout: 2.1)
    }
}

private actor TestWirelessADB: WirelessADBConnecting {
    private let connectedDevice: AndroidDevice
    private let pausePairing: Bool
    private let pauseConnecting: Bool
    private var pendingPairing: CheckedContinuation<Void, Never>?
    private var pendingConnection: CheckedContinuation<Void, Never>?
    private var pairingStarted = false
    private var connectingStarted = false
    private var pairs = 0
    private var connections = 0

    init(connectedDevice: AndroidDevice, pausePairing: Bool = false, pauseConnecting: Bool = false) {
        self.connectedDevice = connectedDevice
        self.pausePairing = pausePairing
        self.pauseConnecting = pauseConnecting
    }

    func pair(endpoint: ADBWirelessEndpoint, code: ADBPairingCode) async throws {
        pairs += 1
        if pausePairing {
            await withCheckedContinuation { continuation in
                pendingPairing = continuation
                pairingStarted = true
            }
        }
    }

    func connect(endpoint: ADBWirelessEndpoint) async throws -> AndroidDevice {
        connections += 1
        if pauseConnecting {
            await withCheckedContinuation { continuation in
                pendingConnection = continuation
                connectingStarted = true
            }
        }
        return connectedDevice
    }

    func waitUntilPairingStarts() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !pairingStarted && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return pairingStarted
    }

    func waitUntilConnectingStarts() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !connectingStarted && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return connectingStarted
    }

    func completePairing() {
        pendingPairing?.resume()
        pendingPairing = nil
    }

    func completeConnection() {
        pendingConnection?.resume()
        pendingConnection = nil
    }

    func pairingCount() -> Int { pairs }
    func connectionCount() -> Int { connections }
}
