//
//  SonyRemoteProtocolTests.swift
//  smart-teleprompterTests
//

import Foundation
import Testing
@testable import smart_teleprompter

struct SonyRemoteProtocolTests {

    @Test func recordToggleIsPressThenRelease() {
        let bytes = SonyRemoteProtocol.toggleRecordSequence.map { [UInt8]($0.data) }
        #expect(bytes == [[0x01, 0x0F], [0x01, 0x0E]])
    }

    @Test func decodesRecordingNotifications() {
        #expect(SonyRemoteProtocol.event(from: Data([0x02, 0xD5, 0x20])) == .recordingStarted)
        #expect(SonyRemoteProtocol.event(from: Data([0x02, 0xD5, 0x00])) == .recordingStopped)
    }

    @Test func decodesFocusAndShutterNotifications() {
        #expect(SonyRemoteProtocol.event(from: Data([0x02, 0x3F, 0x20])) == .focusAcquired)
        #expect(SonyRemoteProtocol.event(from: Data([0x02, 0x3F, 0x00])) == .focusLost)
        #expect(SonyRemoteProtocol.event(from: Data([0x02, 0xA0, 0x20])) == .shutterActive)
    }

    @Test func ignoresUnknownOrShortNotifications() {
        #expect(SonyRemoteProtocol.event(from: Data([0x02, 0xD5])) == nil)
        #expect(SonyRemoteProtocol.event(from: Data([0x01, 0xD5, 0x20])) == nil)
        #expect(SonyRemoteProtocol.event(from: Data([0x02, 0x11, 0x20])) == nil)
    }

    @Test func recognizesSonyCameraAdvertisement() {
        #expect(SonyRemoteProtocol.isSonyCamera(manufacturerData: Data([0x2D, 0x01, 0x03, 0x00, 0x64, 0x00])))
    }

    @Test func rejectsOtherAdvertisements() {
        #expect(!SonyRemoteProtocol.isSonyCamera(manufacturerData: nil))
        #expect(!SonyRemoteProtocol.isSonyCamera(manufacturerData: Data([0x4C, 0x00, 0x03, 0x00])))   // Apple
        #expect(!SonyRemoteProtocol.isSonyCamera(manufacturerData: Data([0x2D, 0x01, 0x01, 0x00])))   // Sony, not a camera
        #expect(!SonyRemoteProtocol.isSonyCamera(manufacturerData: Data([0x2D, 0x01])))
    }
}
