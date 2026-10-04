//
//  UVCCameraFeed.swift
//  smart-teleprompter
//
//  Live preview of a Sony camera plugged in over USB in "USB Streaming" mode,
//  where it shows up as a standard UVC webcam. Prefers a camera whose name
//  mentions Sony and follows plug/unplug while the presenter is open.
//

import AVFoundation
import Observation
import os

@MainActor
@Observable
final class UVCCameraFeed {

    enum State: Equatable {
        case idle
        case authorizing
        case unauthorized
        /// No external camera is plugged in.
        case noCamera
        case running(cameraName: String)
        case failed(String)
    }

    private(set) var state: State = .idle

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Shared with the preview layer; configured only on the runner's queue.
    var session: AVCaptureSession { runner.session }

    @ObservationIgnored private let runner = CaptureSessionRunner()
    @ObservationIgnored private var currentDeviceID: String?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isActive = false

    func start() async {
        guard !isActive else { return }
        isActive = true
        state = .authorizing
        guard await Self.authorize() else {
            if isActive { state = .unauthorized }
            return
        }
        guard isActive else { return }
        observeDevices()
        attachPreferredCamera()
    }

    func stop() {
        isActive = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        currentDeviceID = nil
        runner.use(nil)
        state = .idle
    }

    // MARK: - Devices

    private static func externalCameras() -> [AVCaptureDevice] {
        #if os(visionOS)
        return []
        #else
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video,
                                                position: .unspecified).devices
        #endif
    }

    private func attachPreferredCamera() {
        guard isActive else { return }
        let cameras = Self.externalCameras()
        guard let device = cameras.first(where: { $0.localizedName.localizedCaseInsensitiveContains("sony") })
                ?? cameras.first
        else {
            currentDeviceID = nil
            runner.use(nil)
            state = .noCamera
            return
        }
        guard device.uniqueID != currentDeviceID else { return }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            currentDeviceID = device.uniqueID
            runner.use(input)
            state = .running(cameraName: device.localizedName)
            Log.camera.info("USB camera feed: \(device.localizedName, privacy: .public)")
        } catch {
            Log.camera.error("USB camera failed: \(error.localizedDescription, privacy: .public)")
            currentDeviceID = nil
            runner.use(nil)
            state = .failed(error.localizedDescription)
        }
    }

    private func observeDevices() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [AVCaptureDevice.wasConnectedNotification,
                                          AVCaptureDevice.wasDisconnectedNotification]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let disconnectedID = name == AVCaptureDevice.wasDisconnectedNotification
                    ? (notification.object as? AVCaptureDevice)?.uniqueID : nil
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let disconnectedID, disconnectedID == self.currentDeviceID { self.currentDeviceID = nil }
                    self.attachPreferredCamera()
                }
            }
        }
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                            object: runner.session, queue: .main) { [weak self] notification in
            let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                Log.camera.error("USB camera session error: \(message ?? "unknown", privacy: .public)")
                self.state = .failed(message ?? String(localized: "The camera feed stopped."))
                self.currentDeviceID = nil
            }
        })
    }

    private static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

/// Owns the capture session and performs its blocking calls off the main thread.
nonisolated private final class CaptureSessionRunner: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "rxlab.smart-teleprompter.uvc-session")

    /// Swaps in `input` (or removes every input for `nil`) and starts or stops the session to match.
    func use(_ input: AVCaptureDeviceInput?) {
        nonisolated(unsafe) let input = input
        queue.async { [session] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            if let input, session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            if session.inputs.isEmpty {
                if session.isRunning { session.stopRunning() }
            } else if !session.isRunning {
                session.startRunning()
            }
        }
    }
}
