//
//  UVCCameraFeed.swift
//  smart-teleprompter
//
//  Live preview of a Sony camera plugged in over USB in "USB Streaming" mode,
//  where it shows up as a standard UVC webcam. Prefers a camera whose name
//  mentions Sony and follows plug/unplug while the presenter is open.
//  Sony cameras can't record to their card while streaming, so the feed can
//  also be recorded on this device and saved to Photos.
//

import AVFoundation
import Observation
import os
import Photos

@MainActor
@Observable
final class UVCCameraFeed {

    enum State: Equatable {
        case idle
        case authorizing
        case unauthorized
        /// No external camera is plugged in.
        case noCamera
        /// The session is starting; the preview waits so the main thread never blocks on it.
        case starting(cameraName: String)
        case running(cameraName: String)
        case failed(String)
    }

    enum RecordingOutcome: Equatable {
        case savedToPhotos
        /// Photos refused the movie, so it was kept in the app's Documents folder.
        case savedToFiles
        case photosAccessDenied
        case failed(String)
    }

    /// A fresh value per finished recording, so repeated outcomes still notify observers.
    struct RecordingResult: Equatable {
        let id = UUID()
        let outcome: RecordingOutcome
    }

    private(set) var state: State = .idle
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    /// True from the end of a recording until the movie is saved.
    private(set) var isSavingRecording = false
    private(set) var lastRecording: RecordingResult?

    var canRecord: Bool { isRunning && !isRecording && !isSavingRecording }

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
        isRecording = false
        recordingStartedAt = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        currentDeviceID = nil
        runner.use(nil)
        state = .idle
    }

    // MARK: - Recording

    func startRecording() async {
        guard canRecord else { return }
        isRecording = true
        recordingStartedAt = Date()
        guard await RecordingLibrary.requestAccess() else {
            isRecording = false
            recordingStartedAt = nil
            lastRecording = RecordingResult(outcome: .photosAccessDenied)
            return
        }
        let includeAudio = await Self.prepareAudio()
        // Stopped or closed while asking for permission; nothing was recorded.
        guard isRecording, isActive else {
            isRecording = false
            recordingStartedAt = nil
            isSavingRecording = false
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartPrompter-\(UUID().uuidString).mov")
        Log.camera.info("USB camera recording to device (audio: \(includeAudio))")
        // Saving runs on its own task so the movie is kept even if the presenter has closed.
        runner.startRecording(to: url, includeAudio: includeAudio) { [weak self] error in
            Task { @MainActor in
                self?.recordingDidStop()
                let outcome = await RecordingLibrary.save(url, error: error)
                self?.recordingDidSave(outcome)
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recordingDidStop()
        runner.stopRecording()
    }

    private func recordingDidStop() {
        isRecording = false
        recordingStartedAt = nil
        isSavingRecording = true
    }

    private func recordingDidSave(_ outcome: RecordingOutcome) {
        isSavingRecording = false
        lastRecording = RecordingResult(outcome: outcome)
    }

    /// Records sound only when the microphone is allowed. The capture session shares the
    /// app's audio session with voice following, so it is set up the same way here.
    private static func prepareAudio() async -> Bool {
        let granted = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
        guard granted else { return false }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            do {
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                Log.camera.error("Audio session for recording failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        #endif
        return true
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
            let deviceID = device.uniqueID
            let name = device.localizedName
            currentDeviceID = deviceID
            state = .starting(cameraName: name)
            Log.camera.info("USB camera feed starting: \(name, privacy: .public)")
            // `startRunning` can stall for as long as the camera is busy (e.g. while its
            // Bluetooth remote connects); the preview attaches only once it has returned.
            runner.use(input) { [weak self] started in
                Task { @MainActor in
                    guard let self, self.isActive, self.currentDeviceID == deviceID else { return }
                    Log.camera.info("USB camera feed \(started ? "running" : "failed to start"): \(name, privacy: .public)")
                    self.state = started ? .running(cameraName: name)
                                         : .failed(String(localized: "Couldn't start the camera feed."))
                }
            }
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
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let message = error?.localizedDescription
            let detail = error.map { "\($0.domain) \($0.code) \($0.userInfo)" } ?? "unknown"
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                Log.camera.error("USB camera session error: \(detail, privacy: .public)")
                self.state = .failed(message ?? String(localized: "The camera feed stopped."))
                self.isRecording = false
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
    // Touched only on `queue`.
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    #if !os(visionOS)
    private var movieOutput: AVCaptureMovieFileOutput?
    private var recordingDelegate: MovieRecordingDelegate?
    #endif

    init() {
        #if os(iOS)
        // Keep voice following's audio session as is instead of letting capture reconfigure it.
        session.automaticallyConfiguresApplicationAudioSession = false
        #endif
    }

    /// Swaps in `input` (or removes every input for `nil`) and starts or stops the session to match.
    /// `onStarted` reports, once the session settles, whether the new input is live.
    func use(_ input: AVCaptureDeviceInput?, onStarted: (@Sendable (Bool) -> Void)? = nil) {
        nonisolated(unsafe) let input = input
        queue.async { [self] in
            #if !os(visionOS)
            if input == nil { movieOutput?.stopRecording() }
            #endif
            session.beginConfiguration()
            if let videoInput { session.removeInput(videoInput) }
            videoInput = nil
            if input == nil, let audioInput {
                session.removeInput(audioInput)
                self.audioInput = nil
            }
            if let input, session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            }
            session.commitConfiguration()
            if videoInput == nil {
                if session.isRunning { session.stopRunning() }
            } else if !session.isRunning {
                session.startRunning()
            }
            onStarted?(videoInput != nil && session.isRunning)
        }
    }

    /// Records the feed to `url`; `onFinish` gets `nil` once a playable movie is written.
    func startRecording(to url: URL, includeAudio: Bool, onFinish: @escaping @Sendable (Error?) -> Void) {
        #if os(visionOS)
        onFinish(CocoaError(.featureUnsupported))
        #else
        queue.async { [self] in
            guard videoInput != nil else {
                onFinish(CocoaError(.fileWriteUnknown))
                return
            }
            session.beginConfiguration()
            if includeAudio, audioInput == nil, let microphone = Self.preferredMicrophone(),
               let input = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            }
            if movieOutput == nil {
                let output = AVCaptureMovieFileOutput()
                if session.canAddOutput(output) {
                    session.addOutput(output)
                    movieOutput = output
                }
            }
            session.commitConfiguration()
            guard let movieOutput else {
                onFinish(CocoaError(.fileWriteUnknown))
                return
            }
            // Like the preview, record the external camera's frames as delivered.
            if let connection = movieOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
            let delegate = MovieRecordingDelegate(runner: self, onFinish: onFinish)
            recordingDelegate = delegate
            movieOutput.startRecording(to: url, recordingDelegate: delegate)
        }
        #endif
    }

    func stopRecording() {
        #if !os(visionOS)
        queue.async { [self] in movieOutput?.stopRecording() }
        #endif
    }

    #if !os(visionOS)
    /// Releases the microphone between recordings.
    fileprivate func recordingDidFinish() {
        queue.async { [self] in
            recordingDelegate = nil
            guard let audioInput else { return }
            session.beginConfiguration()
            session.removeInput(audioInput)
            session.commitConfiguration()
            self.audioInput = nil
        }
    }

    /// iOS follows the audio route (a plugged-in camera's USB audio included); on the Mac, prefer the Sony's own microphone.
    private static func preferredMicrophone() -> AVCaptureDevice? {
        #if os(macOS)
        let microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio,
                                                           position: .unspecified).devices
        return microphones.first { $0.localizedName.localizedCaseInsensitiveContains("sony") }
            ?? AVCaptureDevice.default(for: .audio)
        #else
        return AVCaptureDevice.default(for: .audio)
        #endif
    }
    #endif
}

#if !os(visionOS)
/// Holds on to the runner (and its session) until the movie file is finalized,
/// so a recording survives the presenter closing mid-take.
nonisolated private final class MovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private var runner: CaptureSessionRunner?
    private let onFinish: @Sendable (Error?) -> Void

    init(runner: CaptureSessionRunner, onFinish: @escaping @Sendable (Error?) -> Void) {
        self.runner = runner
        self.onFinish = onFinish
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        // Stopping the session or unplugging the camera still leaves a playable movie.
        let finished = error == nil
            || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        onFinish(finished ? nil : error)
        runner?.recordingDidFinish()
        runner = nil
    }
}
#endif

/// Saves finished recordings to the photo library.
@MainActor
private enum RecordingLibrary {
    static func requestAccess() async -> Bool {
        switch await PHPhotoLibrary.requestAuthorization(for: .addOnly) {
        case .authorized, .limited: true
        default: false
        }
    }

    static func save(_ url: URL, error: Error?) async -> UVCCameraFeed.RecordingOutcome {
        if let error {
            Log.camera.error("USB camera recording failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
            return .failed(error.localizedDescription)
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            try? FileManager.default.removeItem(at: url)
            Log.camera.info("USB camera recording saved to Photos")
            return .savedToPhotos
        } catch {
            Log.camera.error("Saving recording to Photos failed: \(error.localizedDescription, privacy: .public)")
            return keepInDocuments(url)
        }
    }

    /// Never drop a take: fall back to the app's Documents folder.
    private static func keepInDocuments(_ url: URL) -> UVCCameraFeed.RecordingOutcome {
        do {
            let folder = URL.documentsDirectory.appendingPathComponent("Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(url.lastPathComponent))
            return .savedToFiles
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
