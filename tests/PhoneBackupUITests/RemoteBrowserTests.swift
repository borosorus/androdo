import XCTest
@testable import PhoneBackupCore
@testable import PhoneBackupUI

@MainActor
final class RemoteBrowserTests: XCTestCase {
    func testSharedStorageOpensWhenDeviceBecomesReadyAfterInitialVisit() async throws {
        let id = try DeviceID(value: "browser-reconnect-test")
        let device = fixtureDevice(id: id, state: .device)
        let transport = FakeDeviceTransport(devices: [device])
        let root = try RemotePath("/sdcard")
        await transport.seed(RemoteEntry(path: root, kind: .directory), on: id)
        let browser = RemoteBrowserModel(remote: transport)

        await browser.openRoot()
        XCTAssertFalse(browser.hasOpenedRoot)
        let beforeDevice = await transport.recordedChildrenCalls(on: id)
        XCTAssertTrue(beforeDevice.isEmpty)

        browser.setDevice(device)
        await browser.openRoot()

        XCTAssertEqual(browser.currentDirectory, root)
        XCTAssertTrue(browser.hasOpenedRoot)
        let afterDevice = await transport.recordedChildrenCalls(on: id)
        XCTAssertEqual(afterDevice, [root])
    }

    func testOpeningBrowserListsOnlyTheRequestedDirectory() async throws {
        let id = try DeviceID(value: "browser-test")
        let device = fixtureDevice(id: id, state: .device)
        let transport = FakeDeviceTransport(devices: [device])
        let root = try RemotePath("/sdcard")
        let folder = try root.appending("Pictures")
        await transport.seed(RemoteEntry(path: folder, kind: .directory), on: id)
        await transport.seed(RemoteEntry(path: try folder.appending("photo.jpg"), kind: .file, size: 3), on: id, data: Data([1, 2, 3]))
        let browser = RemoteBrowserModel(remote: transport)
        browser.setDevice(device)

        let beforeOpen = await transport.recordedChildrenCalls(on: id)
        XCTAssertTrue(beforeOpen.isEmpty)
        await browser.openRoot()
        XCTAssertEqual(browser.currentDirectory, root)
        let afterRoot = await transport.recordedChildrenCalls(on: id)
        XCTAssertEqual(afterRoot, [root])

        await browser.open(try XCTUnwrap(browser.entries.first))
        XCTAssertEqual(browser.currentDirectory, folder)
        XCTAssertEqual(browser.entries.map(\.name), ["photo.jpg"])
        let afterFolder = await transport.recordedChildrenCalls(on: id)
        XCTAssertEqual(afterFolder, [root, folder])
    }

    func testEmptyAndDeniedFoldersHaveDifferentStates() async throws {
        let id = try DeviceID(value: "browser-error-test")
        let device = fixtureDevice(id: id, state: .device)
        let transport = FakeDeviceTransport(devices: [device])
        let root = try RemotePath("/sdcard")
        await transport.seed(RemoteEntry(path: root, kind: .directory), on: id)
        let browser = RemoteBrowserModel(remote: transport)
        browser.setDevice(device)

        await browser.navigate(to: root)
        XCTAssertTrue(browser.entries.isEmpty)
        XCTAssertNil(browser.errorMessage)

        await transport.failNext(.inaccessiblePath(root), operation: .children, at: root, on: id)
        await browser.refresh()
        XCTAssertTrue(browser.entries.isEmpty)
        XCTAssertNotNil(browser.errorMessage)
    }

    func testSortAndSelectionDoNotRequestMoreDirectoryListings() async throws {
        let id = try DeviceID(value: "browser-sort-test")
        let device = fixtureDevice(id: id, state: .device)
        let transport = FakeDeviceTransport(devices: [device])
        let root = try RemotePath("/sdcard")
        await transport.seed(RemoteEntry(path: try root.appending("z.txt"), kind: .file, size: 4), on: id)
        await transport.seed(RemoteEntry(path: try root.appending("a.txt"), kind: .file, size: 2), on: id)
        let browser = RemoteBrowserModel(remote: transport)
        browser.setDevice(device)
        await browser.navigate(to: root)
        browser.selection = [try root.appending("z.txt")]
        browser.sort(by: .size, ascending: true)

        XCTAssertEqual(browser.entries.map(\.name), ["a.txt", "z.txt"])
        XCTAssertEqual(browser.selection, [try root.appending("z.txt")])
        let calls = await transport.recordedChildrenCalls(on: id)
        XCTAssertEqual(calls, [root])
    }
}
