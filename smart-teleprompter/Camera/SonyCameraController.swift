//
//  SonyCameraController.swift
//  smart-teleprompter
//
//  Finds, pairs, and reconnects to a Sony camera over Bluetooth LE and drives
//  its record button. The paired camera is remembered so it reconnects on its
//  own whenever it is in range with Bluetooth remote control on.
//

import CoreBluetooth
import Foundation
import Observation
import os

@MainActor
@Observable
final class SonyCameraController: NSObject {

    struct DiscoveredCamera: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
    }

    enum State: Equatable {
        case bluetoothOff
        case unauthorized
        case unsupported
        case idle
        case connecting
        /// Connected and the remote characteristics are ready for commands.
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var isScanning = false
    private(set) var discovered: [DiscoveredCamera] = []
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    private(set) var pairedCameraID: UUID?
    private(set) var pairedCameraName: String?

    var isReady: Bool { state == .ready }

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var activePeripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var scanRequested = false
    private var connectingName: String?
    /// Recording state before the last toggle, restored if the command fails to send.
    private var recordingBeforeToggle: Bool?

    private let defaults: UserDefaults
    private static let pairedIDKey = "sonyCamera.pairedID"
    private static let pairedNameKey = "sonyCamera.pairedName"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pairedCameraID = defaults.string(forKey: Self.pairedIDKey).flatMap(UUID.init(uuidString:))
        pairedCameraName = defaults.string(forKey: Self.pairedNameKey)
        super.init()
    }

    /// Creates the central lazily so the Bluetooth permission prompt only appears
    /// once the user has paired a camera or opens the pairing screen.
    func activate() {
        guard central == nil else { return }
        Log.camera.debug("Creating central manager (paired: \(self.pairedCameraID?.uuidString ?? "none", privacy: .public))")
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// Reconnects to a previously paired camera at launch without prompting first-time users.
    func activateIfPaired() {
        if pairedCameraID != nil { activate() }
    }

    // MARK: - Scanning

    func startScan() {
        scanRequested = true
        activate()
        guard let central, central.state == .poweredOn, !central.isScanning else {
            Log.camera.debug("Scan deferred: central state \(self.central?.state.rawValue ?? -1), scanning \(self.central?.isScanning ?? false)")
            return
        }
        discovered.removeAll()
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        Log.camera.info("Scanning for Sony cameras")
    }

    func stopScan() {
        scanRequested = false
        central?.stopScan()
        isScanning = false
    }

    // MARK: - Connection

    func connect(to camera: DiscoveredCamera) {
        guard let central, let peripheral = peripherals[camera.id] else {
            Log.camera.error("Connect ignored: no peripheral for \(camera.id.uuidString, privacy: .public)")
            return
        }
        Log.camera.info("Connecting to \(camera.name, privacy: .public) (\(camera.id.uuidString, privacy: .public), RSSI \(camera.rssi))")
        stopScan()
        if let activePeripheral, activePeripheral.identifier != peripheral.identifier {
            central.cancelPeripheralConnection(activePeripheral)
        }
        connectingName = camera.name
        connect(peripheral)
    }

    func forgetCamera() {
        Log.camera.info("Forgetting camera \(self.pairedCameraID?.uuidString ?? "none", privacy: .public)")
        if let activePeripheral { central?.cancelPeripheralConnection(activePeripheral) }
        activePeripheral = nil
        commandCharacteristic = nil
        pairedCameraID = nil
        pairedCameraName = nil
        isRecording = false
        recordingStartedAt = nil
        defaults.removeObject(forKey: Self.pairedIDKey)
        defaults.removeObject(forKey: Self.pairedNameKey)
        if central?.state == .poweredOn { state = .idle }
    }

    private func connect(_ peripheral: CBPeripheral) {
        activePeripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        Log.camera.debug("connect() → \(peripheral.identifier.uuidString, privacy: .public), peripheral state \(peripheral.state.rawValue)")
        // No timeout: CoreBluetooth completes this whenever the camera comes into range.
        central?.connect(peripheral, options: nil)
    }

    func reconnectToPairedCamera() {
        guard activePeripheral == nil, let central, let pairedCameraID else {
            Log.camera.debug("Reconnect skipped: active \(self.activePeripheral != nil), paired \(self.pairedCameraID != nil)")
            return
        }
        guard let peripheral = central.retrievePeripherals(withIdentifiers: [pairedCameraID]).first else {
            Log.camera.error("Reconnect failed: system doesn't know paired camera \(pairedCameraID.uuidString, privacy: .public)")
            return
        }
        Log.camera.info("Reconnecting to paired camera \(self.pairedCameraName ?? "unknown", privacy: .public)")
        peripherals[pairedCameraID] = peripheral
        connect(peripheral)
    }

    // MARK: - Recording

    func toggleRecording() {
        guard let peripheral = activePeripheral, let characteristic = commandCharacteristic else {
            Log.camera.error("Toggle ignored: state \(String(describing: self.state), privacy: .public), peripheral \(self.activePeripheral != nil), command characteristic \(self.commandCharacteristic != nil)")
            return
        }
        Log.camera.info("Toggle on \(peripheral.identifier.uuidString, privacy: .public), peripheral state \(peripheral.state.rawValue), FF01 properties \(Self.describe(characteristic.properties), privacy: .public)")
        for command in SonyRemoteProtocol.toggleRecordSequence {
            Log.camera.debug("Write \(String(describing: command), privacy: .public) [\(command.data.hexString, privacy: .public)]")
            peripheral.writeValue(command.data, for: characteristic, type: .withResponse)
        }
        // Optimistic; FF02 notifications correct this if the camera disagrees.
        recordingBeforeToggle = isRecording
        setRecording(!isRecording)
        Log.camera.info("Toggled recording → \(self.isRecording)")
    }

    private func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        recordingStartedAt = recording ? Date() : nil
    }

    private func handleDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == activePeripheral?.identifier else {
            Log.camera.debug("Ignoring disconnect from inactive peripheral \(peripheral.identifier.uuidString, privacy: .public)")
            return
        }
        commandCharacteristic = nil
        isRecording = false
        recordingStartedAt = nil
        if Self.isStaleBond(error) {
            failStaleBond(peripheral)
        } else if peripheral.identifier == pairedCameraID {
            // Keep a pending connection open so the camera reattaches when it returns.
            connect(peripheral)
        } else {
            activePeripheral = nil
            state = error.map { .failed($0.localizedDescription) } ?? .idle
        }
    }

    private func markReady(_ peripheral: CBPeripheral) {
        if peripheral.identifier != pairedCameraID { pairedCameraName = nil }
        pairedCameraID = peripheral.identifier
        pairedCameraName = peripheral.name ?? connectingName ?? pairedCameraName
        connectingName = nil
        defaults.set(peripheral.identifier.uuidString, forKey: Self.pairedIDKey)
        defaults.set(pairedCameraName, forKey: Self.pairedNameKey)
        state = .ready
        Log.camera.info("Camera ready: \(self.pairedCameraName ?? "unknown", privacy: .public)")
    }

    private func fail(_ peripheral: CBPeripheral, _ message: String) {
        Log.camera.error("Camera failed: \(message, privacy: .public)")
        // Clear first so the resulting disconnect callback doesn't start a reconnect loop.
        activePeripheral = nil
        commandCharacteristic = nil
        connectingName = nil
        central?.cancelPeripheralConnection(peripheral)
        state = .failed(message)
    }

    /// The camera dropped its bond but this device still holds the old keys, so every
    /// reconnect fails until the user forgets the camera in system Bluetooth settings.
    private func failStaleBond(_ peripheral: CBPeripheral) {
        let name = pairedCameraName ?? connectingName ?? peripheral.name ?? String(localized: "Sony Camera")
        forgetCamera()
        fail(peripheral, String(localized: "\(name) no longer recognizes this device. Open Settings › Bluetooth, choose Forget This Device for \(name), then on the camera open Bluetooth › Pairing and pair again."))
    }

    private static func describe(_ properties: CBCharacteristicProperties) -> String {
        let names: [(CBCharacteristicProperties, String)] = [
            (.read, "read"), (.write, "write"), (.writeWithoutResponse, "writeWithoutResponse"),
            (.notify, "notify"), (.indicate, "indicate"),
            (.notifyEncryptionRequired, "notifyEncrypted"), (.indicateEncryptionRequired, "indicateEncrypted"),
        ]
        return names.filter { properties.contains($0.0) }.map(\.1).joined(separator: ",")
    }

    nonisolated private static func describe(_ error: Error?) -> String {
        guard let error else { return "none" }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    private static func isStaleBond(_ error: Error?) -> Bool {
        (error as? CBError)?.code == .peerRemovedPairingInformation
    }

    private static let pairingHint = String(localized: "Couldn’t pair. On the camera, turn on Bluetooth Rmt Ctrl and open Bluetooth › Pairing, then try again.")
}

// MARK: - CBCentralManagerDelegate

extension SonyCameraController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            Log.camera.info("Central state → \(central.state.rawValue) (0 unknown, 1 resetting, 2 unsupported, 3 unauthorized, 4 off, 5 on)")
            switch central.state {
            case .poweredOn:
                if state == .bluetoothOff || state == .unauthorized || state == .unsupported { state = .idle }
                reconnectToPairedCamera()
                if scanRequested { startScan() }
            case .poweredOff:
                state = .bluetoothOff
                isScanning = false
                isRecording = false
                recordingStartedAt = nil
                activePeripheral = nil
                commandCharacteristic = nil
            case .unauthorized:
                state = .unauthorized
            case .unsupported:
                state = .unsupported
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        guard SonyRemoteProtocol.isSonyCamera(manufacturerData: manufacturerData) else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            peripherals[peripheral.identifier] = peripheral
            let camera = DiscoveredCamera(id: peripheral.identifier,
                                          name: name ?? String(localized: "Sony Camera"),
                                          rssi: rssi)
            if let index = discovered.firstIndex(where: { $0.id == camera.id }) {
                discovered[index] = camera
            } else {
                Log.camera.info("Discovered \(camera.name, privacy: .public) (\(camera.id.uuidString, privacy: .public)), RSSI \(rssi), mfr data \(manufacturerData?.hexString ?? "-", privacy: .public)")
                discovered.append(camera)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            Log.camera.info("Connected to \(peripheral.name ?? "unknown", privacy: .public); discovering remote service")
            peripheral.discoverServices([SonyRemoteProtocol.remoteService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            Log.camera.error("Failed to connect: \(Self.describe(error), privacy: .public)")
            if Self.isStaleBond(error) {
                failStaleBond(peripheral)
            } else {
                fail(peripheral, error?.localizedDescription ?? Self.pairingHint)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        MainActor.assumeIsolated {
            Log.camera.info("Disconnected (system reconnecting: \(isReconnecting)): \(Self.describe(error), privacy: .public)")
            handleDisconnect(peripheral, error: error)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension SonyCameraController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let services = (peripheral.services ?? []).map(\.uuid.uuidString).joined(separator: ", ")
            Log.camera.info("Services: [\(services, privacy: .public)], error: \(Self.describe(error), privacy: .public)")
            guard error == nil,
                  let service = peripheral.services?.first(where: { $0.uuid == SonyRemoteProtocol.remoteService })
            else {
                fail(peripheral, String(localized: "This camera doesn’t offer Bluetooth remote control. Turn on Bluetooth Rmt Ctrl in the camera’s network menu."))
                return
            }
            peripheral.discoverCharacteristics([SonyRemoteProtocol.commandCharacteristic,
                                                SonyRemoteProtocol.notifyCharacteristic], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            let characteristics = service.characteristics ?? []
            for characteristic in characteristics {
                Log.camera.info("Characteristic \(characteristic.uuid.uuidString, privacy: .public): \(Self.describe(characteristic.properties), privacy: .public)")
            }
            if let error { Log.camera.error("Characteristic discovery failed: \(Self.describe(error), privacy: .public)") }
            guard error == nil,
                  let command = characteristics.first(where: { $0.uuid == SonyRemoteProtocol.commandCharacteristic })
            else {
                fail(peripheral, Self.pairingHint)
                return
            }
            commandCharacteristic = command
            if let notify = characteristics.first(where: { $0.uuid == SonyRemoteProtocol.notifyCharacteristic }) {
                // Subscribing needs an encrypted link, which brings up the pairing prompt
                // on first use. Readiness is confirmed in didUpdateNotificationStateFor.
                peripheral.setNotifyValue(true, for: notify)
            } else {
                markReady(peripheral)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                Log.camera.error("Subscribe to \(characteristic.uuid.uuidString, privacy: .public) failed: \(Self.describe(error), privacy: .public)")
                if Self.isStaleBond(error) {
                    failStaleBond(peripheral)
                } else {
                    fail(peripheral, Self.pairingHint)
                }
            } else {
                Log.camera.info("Subscribed to \(characteristic.uuid.uuidString, privacy: .public) (notifying: \(characteristic.isNotifying))")
                markReady(peripheral)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString
        let data = characteristic.value
        let errorDescription = error.map { Self.describe($0) }
        MainActor.assumeIsolated {
            if let errorDescription {
                Log.camera.error("Notification error on \(uuid, privacy: .public): \(errorDescription, privacy: .public)")
            }
            let raw = data?.hexString ?? "-"
            guard let data, let event = SonyRemoteProtocol.event(from: data) else {
                Log.camera.debug("Notification \(uuid, privacy: .public) [\(raw, privacy: .public)]: unrecognized")
                return
            }
            Log.camera.info("Notification \(uuid, privacy: .public) [\(raw, privacy: .public)] → \(String(describing: event), privacy: .public)")
            switch event {
            case .recordingStarted, .recordingStopped: recordingBeforeToggle = nil
            default: break
            }
            switch event {
            case .recordingStarted: setRecording(true)
            case .recordingStopped: setRecording(false)
            default: break
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString
        let message = error.map { Self.describe($0) }
        MainActor.assumeIsolated {
            guard let message else {
                Log.camera.debug("Write to \(uuid, privacy: .public) acknowledged")
                return
            }
            Log.camera.error("Command to \(uuid, privacy: .public) failed: \(message, privacy: .public)")
            // The write never reached the camera, so undo the optimistic toggle.
            if let recordingBeforeToggle { setRecording(recordingBeforeToggle) }
            recordingBeforeToggle = nil
        }
    }
}

private extension Data {
    nonisolated var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
