//
//  CameraPreviewView.swift
//  smart-teleprompter
//
//  Hosts an AVCaptureVideoPreviewLayer for the USB camera feed.
//

import AVFoundation
import SwiftUI

#if os(iOS) || os(macOS)
/// Keeps the preview layer as a sublayer so it can be flipped without
/// fighting the host view's own frame management.
private func layoutPreview(_ layer: AVCaptureVideoPreviewLayer, in bounds: CGRect,
                           flipHorizontal: Bool, flipVertical: Bool) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // `frame` is undefined under a non-identity transform; size via bounds + position.
    layer.bounds = CGRect(origin: .zero, size: bounds.size)
    layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    layer.setAffineTransform(CGAffineTransform(scaleX: flipHorizontal ? -1 : 1,
                                               y: flipVertical ? -1 : 1))
    CATransaction.commit()
}

/// iOS defaults the preview connection to a portrait (90°) rotation, which is
/// right for built-in cameras but turns a USB camera's landscape frames on
/// their side. An external camera isn't fixed to the device, so show its
/// frames as delivered.
nonisolated private func keepUpright(_ layer: AVCaptureVideoPreviewLayer) {
    guard let connection = layer.connection, connection.videoRotationAngle != 0,
          connection.isVideoRotationAngleSupported(0) else { return }
    connection.videoRotationAngle = 0
}

/// The preview connection only exists once the session has an input, which
/// happens off the main thread, so re-apply the rotation whenever it starts.
/// Runs on the session's own queue (the one that called `startRunning`), never
/// from layout: touching the connection there blocks the main thread on the
/// session and, when the change doesn't stick, re-triggers layout forever.
private func observeSessionStart(_ session: AVCaptureSession,
                                 layer: AVCaptureVideoPreviewLayer) -> NSObjectProtocol {
    nonisolated(unsafe) let layer = layer
    return NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification,
                                                  object: session, queue: nil) { [weak layer] _ in
        if let layer { keepUpright(layer) }
    }
}
#endif

#if os(iOS)
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var flipHorizontal = false
    var flipVertical = false

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.startObserver = observeSessionStart(session, layer: view.previewLayer)
        keepUpright(view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.flipHorizontal = flipHorizontal
        view.flipVertical = flipVertical
    }

    final class PreviewView: UIView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var flipHorizontal = false { didSet { setNeedsLayout() } }
        var flipVertical = false { didSet { setNeedsLayout() } }
        var startObserver: NSObjectProtocol?

        deinit { startObserver.map(NotificationCenter.default.removeObserver) }

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutPreview(previewLayer, in: bounds, flipHorizontal: flipHorizontal, flipVertical: flipVertical)
        }
    }
}
#elseif os(macOS)
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var flipHorizontal = false
    var flipVertical = false

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.startObserver = observeSessionStart(session, layer: view.previewLayer)
        keepUpright(view.previewLayer)
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.flipHorizontal = flipHorizontal
        view.flipVertical = flipVertical
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var flipHorizontal = false { didSet { needsLayout = true } }
        var flipVertical = false { didSet { needsLayout = true } }
        var startObserver: NSObjectProtocol?

        deinit { startObserver.map(NotificationCenter.default.removeObserver) }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = .black
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            layoutPreview(previewLayer, in: bounds, flipHorizontal: flipHorizontal, flipVertical: flipVertical)
        }
    }
}
#else
struct CameraPreviewView: View {
    let session: AVCaptureSession
    var flipHorizontal = false
    var flipVertical = false

    var body: some View { Color.black }
}
#endif
