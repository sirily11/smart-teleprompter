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
