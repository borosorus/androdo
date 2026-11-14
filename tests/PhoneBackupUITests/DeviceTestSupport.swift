@testable import PhoneBackupCore

func fixtureDevice(id: DeviceID, state: DeviceState = .device, model: String? = nil,
                   product: String? = nil) -> AndroidDevice {
    let sessions = state == .device ? [DeviceSession.fixture(deviceID: id)] : []
    return AndroidDevice(id: id, state: state, model: model, product: product, sessions: sessions)
}
