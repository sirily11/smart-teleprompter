//
//  SpiritLevelView.swift
//  smart-teleprompter
//
//  A bubble level for squaring the iPad up in its rig. It measures left–right
//  tilt along the screen's horizontal edge, so it works both with the iPad
//  standing upright and lying flat under a beam-splitter glass.
//

import SwiftUI
#if os(iOS)
import CoreMotion
import UIKit
#endif

/// Tracks how far the screen's horizontal edge is tilted off level.
@MainActor @Observable
final class DeviceLevel {
    /// Degrees; positive when the right edge of the screen is lower.
    private(set) var tilt: Double = 0
    #if os(iOS)
    private let motion = CMMotionManager()

    var isAvailable: Bool { motion.isDeviceMotionAvailable }
    #else
    var isAvailable: Bool { false }
    #endif

    func start() {
        #if os(iOS)
        guard isAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            let (x, y) = (gravity.x, gravity.y)
            MainActor.assumeIsolated { self?.update(gravityX: x, gravityY: y) }
        }
        #endif
    }

    func stop() {
        #if os(iOS)
        motion.stopDeviceMotionUpdates()
        #endif
    }

    #if os(iOS)
    private func update(gravityX: Double, gravityY: Double) {
        // Gravity along the screen's horizontal axis as the UI is currently laid out.
        let alongScreenX: Double = switch interfaceOrientation {
        case .portraitUpsideDown: -gravityX
        case .landscapeLeft: gravityY
        case .landscapeRight: -gravityY
        default: gravityX
        }
        let degrees = asin(min(max(alongScreenX, -1), 1)) * 180 / .pi
        // Light low-pass so the bubble glides instead of jittering.
        tilt += (degrees - tilt) * 0.25
    }

    private var interfaceOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .effectiveGeometry.interfaceOrientation ?? .portrait
    }
    #endif
}

struct SpiritLevelView: View {
    @State private var level = DeviceLevel()

    /// Tilt at which the bubble reaches the end of the vial.
    private static let fullScaleDegrees = 10.0
    private static let levelTolerance = 0.5
    private static let bubbleSize: CGFloat = 22

    private var isLevel: Bool { abs(level.tilt) < Self.levelTolerance }

    var body: some View {
        if level.isAvailable {
            HStack(spacing: 12) {
                vial
                Text("\(abs(level.tilt), specifier: "%.1f")°")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isLevel ? .green : .secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Level")
            .accessibilityValue(accessibilityValue)
            .onAppear { level.start() }
            .onDisappear { level.stop() }
            .sensoryFeedback(.alignment, trigger: isLevel) { _, nowLevel in nowLevel }
        }
    }

    private var vial: some View {
        GeometryReader { geo in
            let travel = (geo.size.width - Self.bubbleSize) / 2
            let fraction = min(max(level.tilt / Self.fullScaleDegrees, -1), 1)
            ZStack {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                // Centre marks: the bubble sits between them when level.
                HStack(spacing: Self.bubbleSize + 4) {
                    Rectangle().frame(width: 1.5)
                    Rectangle().frame(width: 1.5)
                }
                .foregroundStyle(Color.white.opacity(0.35))
                .padding(.vertical, 5)
                Circle()
                    .fill(isLevel ? Color.green : Color.yellow)
                    .frame(width: Self.bubbleSize, height: Self.bubbleSize)
                    // A bubble floats to the high side, opposite the lower edge.
                    .offset(x: -fraction * travel)
                    .animation(.smooth(duration: 0.2), value: fraction)
            }
        }
        .frame(height: Self.bubbleSize + 8)
    }

    private var accessibilityValue: String {
        if isLevel { return String(localized: "Level") }
        let degrees = abs(level.tilt).formatted(.number.precision(.fractionLength(1)))
        return level.tilt > 0
            ? String(localized: "Right side \(degrees) degrees low")
            : String(localized: "Left side \(degrees) degrees low")
    }
}
