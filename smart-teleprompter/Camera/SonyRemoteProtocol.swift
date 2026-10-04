//
//  SonyRemoteProtocol.swift
//  smart-teleprompter
//
//  Sony's Bluetooth LE remote-control protocol (the one used by the RMT-P1BT
//  remote and Creators' App). Cameras with "Bluetooth Rmt Ctrl" turned on expose
//  a Camera Remote service: commands go to FF01, state changes arrive on FF02.
//  The camera only accepts commands from a bonded device, so the first
//  encrypted access triggers the system pairing prompt.
//

import CoreBluetooth
import Foundation

nonisolated enum SonyRemoteProtocol {
    static let remoteService = CBUUID(string: "8000FF00-FF00-FFFF-FFFF-FFFFFFFFFFFF")
    static let commandCharacteristic = CBUUID(string: "FF01")
    static let notifyCharacteristic = CBUUID(string: "FF02")

    /// Bluetooth SIG company identifier for Sony Corporation.
    static let sonyCompanyID: UInt16 = 0x012D
    /// Product type that follows the company ID in a Sony camera's advertisement.
    static let cameraProductType: UInt16 = 0x0003

    /// Two-byte remote commands. Each button is a "down" then an "up" write.
    enum Command: UInt16 {
        case focusUp = 0x0106
        case focusDown = 0x0107
        case shutterUp = 0x0108
        case shutterDown = 0x0109
        case recordUp = 0x010E
        case recordDown = 0x010F

        var data: Data { Data([UInt8(rawValue >> 8), UInt8(rawValue & 0xFF)]) }
    }

    /// Pressing and releasing the record button toggles movie recording.
    static let toggleRecordSequence: [Command] = [.recordDown, .recordUp]

    enum Event: Equatable {
        case recordingStarted
        case recordingStopped
        case focusAcquired
        case focusLost
        case shutterActive
        case shutterReleased
    }

    /// Decodes a FF02 notification (`02 <type> <value>`); nil for anything unknown.
    static func event(from data: Data) -> Event? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == 0x02 else { return nil }
        let active = bytes[2] == 0x20
        switch bytes[1] {
        case 0xD5: return active ? .recordingStarted : .recordingStopped
        case 0x3F: return active ? .focusAcquired : .focusLost
        case 0xA0: return active ? .shutterActive : .shutterReleased
        default: return nil
        }
    }

    /// True when advertisement manufacturer data identifies a Sony camera.
    static func isSonyCamera(manufacturerData: Data?) -> Bool {
        guard let bytes = manufacturerData.map({ [UInt8]($0) }), bytes.count >= 4 else { return false }
        let company = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        let product = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        return company == sonyCompanyID && product == cameraProductType
    }
}
