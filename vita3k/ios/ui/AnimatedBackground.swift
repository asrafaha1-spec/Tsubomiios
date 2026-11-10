// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreMotion
import SwiftUI

/// Whether the library is on screen (the background stops animating while a game runs) and the
/// phone's tilt, for a little parallax
@MainActor
final class BackgroundMotion: ObservableObject {
    static let shared = BackgroundMotion()

    @Published var active = true
    private(set) var tilt = CGPoint.zero
    private let motion = CMMotionManager()

    func setActive(_ value: Bool) {
        active = value
        if value { startTilt() } else { motion.stopDeviceMotionUpdates() }
    }

    private func startTilt() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive,
              UserDefaults.standard.object(forKey: "v3k.animatedBackground") as? Bool ?? true else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            MainActor.assumeIsolated {
                // Smoothed, small offsets
                let target = CGPoint(x: gravity.x, y: gravity.y + 0.6)
                self?.tilt.x += (target.x - (self?.tilt.x ?? 0)) * 0.1
                self?.tilt.y += (target.y - (self?.tilt.y ?? 0)) * 0.1
            }
        }
    }
}

/// The library background: the theme's gradient with drifting light and the theme's particles
struct AnimatedBackground: View {
    @AppStorage("v3k.theme") private var themeName = AppTheme.midnight.rawValue
    @AppStorage("v3k.animatedBackground") private var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = BackgroundMotion.shared

    var body: some View {
        let theme = AppTheme(rawValue: themeName) ?? .midnight
        let still = !animated || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || !motion.active)) { timeline in
            let time = still ? 0 : timeline.date.timeIntervalSinceReferenceDate
            // Opaque: the whole canvas is painted every frame, and an opaque surface skips the alpha
            // blending that showed as a grid of magenta lines on one iPhone 13 Pro Max (iOS 27.2)
            Canvas(opaque: true) { context, size in
                draw(theme: theme, time: time, tilt: still ? .zero : motion.tilt, context: &context, size: size)
            }
        }
        .onAppear { BackgroundMotion.shared.setActive(true) }
    }

    private func draw(theme: AppTheme, time: Double, tilt: CGPoint, context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        // Nothing is drawn outside the screen (the light blobs are larger than it)
        context.clip(to: Path(rect))
        context.fill(Path(rect), with: .linearGradient(Gradient(colors: theme.backgroundColors),
                                                       startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))

        // Slow drifting light, like an aurora
        let blobs: [(Color, Double, Double, Double)] = [
            (theme.accent, 0.21, 0.0, 0.55), (theme.accent2, 0.15, 2.1, 0.45), (theme.accent, 0.11, 4.2, 0.35),
        ]
        for (index, blob) in blobs.enumerated() {
            let (color, speed, phase, scale) = blob
            let radius = max(size.width, size.height) * scale
            let center = CGPoint(
                x: size.width * (0.5 + 0.38 * sin(time * speed * 0.3 + phase)) + tilt.x * 30 * Double(index + 1),
                y: size.height * (0.4 + 0.3 * cos(time * speed * 0.23 + phase * 1.3)) + tilt.y * 22 * Double(index + 1))
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                         with: .radialGradient(Gradient(colors: [color.opacity(0.22), color.opacity(0)]),
                                               center: center, startRadius: 0, endRadius: radius))
        }

        drawParticles(theme: theme, time: time, tilt: tilt, context: &context, size: size)
    }

    /// Deterministic pseudo-random number in 0..<1 for particle i, salt s
    private func random(_ i: Int, _ s: Int) -> Double {
        let x = sin(Double(i * 127 + s * 311) * 12.9898) * 43758.5453
        return x - floor(x)
    }

    private func drawParticles(theme: AppTheme, time: Double, tilt: CGPoint, context: inout GraphicsContext, size: CGSize) {
        let count = 34
        for i in 0..<count {
            let r1 = random(i, 1), r2 = random(i, 2), r3 = random(i, 3)
            let depth = 0.4 + r3 * 0.6 // nearer particles move more with the tilt
            let shift = CGPoint(x: tilt.x * 18 * depth, y: tilt.y * 14 * depth)
            switch theme {
            case .midnight, .vita:
                // Twinkling stars (Vita: rising blue motes)
                if theme == .vita {
                    let y = (1.1 - fmod(r2 + time * (0.01 + r3 * 0.02), 1.2)) * size.height
                    let x = r1 * size.width + sin(time * 0.5 + r2 * 6) * 12
                    dot(&context, CGPoint(x: x + shift.x, y: y + shift.y), 1.2 + r3 * 2.2, theme.accent2.opacity(0.35 + 0.3 * r3))
                } else {
                    let twinkle = 0.25 + 0.75 * (0.5 + 0.5 * sin(time * (0.8 + r3 * 1.5) + r2 * 10))
                    dot(&context, CGPoint(x: r1 * size.width + shift.x, y: r2 * size.height * 0.85 + shift.y),
                        0.8 + r3 * 1.6, Color.white.opacity(0.55 * twinkle))
                }
            case .sakura:
                // Falling, swaying petals
                let fall = fmod(r2 + time * (0.025 + r3 * 0.03), 1.2) - 0.1
                let x = r1 * size.width + sin(time * (0.6 + r3) + r1 * 8) * 26 + shift.x
                let y = fall * size.height + shift.y
                var petal = context
                petal.translateBy(x: x, y: y)
                petal.rotate(by: .radians(time * (0.6 + r3) + r1 * 6))
                let w = 5 + r3 * 5
                petal.fill(Path(ellipseIn: CGRect(x: -w / 2, y: -w / 4, width: w, height: w / 2)),
                           with: .color(theme.accent2.opacity(0.45 + 0.3 * r3)))
            case .ocean:
                // Rising bubbles
                let y = (1.1 - fmod(r2 + time * (0.02 + r3 * 0.04), 1.2)) * size.height + shift.y
                let x = r1 * size.width + sin(time * 0.9 + r2 * 9) * 10 + shift.x
                let radius = 2 + r3 * 5
                context.stroke(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                               with: .color(theme.accent.opacity(0.35)), lineWidth: 1)
            case .sunset, .crimson:
                // Embers drifting up and fading
                let progress = fmod(r2 + time * (0.03 + r3 * 0.04), 1)
                let y = (1.05 - progress) * size.height + shift.y
                let x = r1 * size.width + sin(time * 1.3 + r1 * 7) * 14 + shift.x
                dot(&context, CGPoint(x: x, y: y), 1 + r3 * 1.8, (r3 > 0.5 ? theme.accent : theme.accent2).opacity(0.7 * (1 - progress)))
            case .forest:
                // Fireflies wandering and blinking
                let x = (r1 + 0.06 * sin(time * (0.3 + r3 * 0.4) + r2 * 9)) * size.width + shift.x
                let y = (0.3 + r2 * 0.7 + 0.05 * cos(time * (0.25 + r3 * 0.3) + r1 * 7)) * size.height + shift.y
                let glow = max(0, sin(time * (0.7 + r3) + r1 * 12))
                let radius = 2 + r3 * 2
                context.fill(Path(ellipseIn: CGRect(x: x - radius * 3, y: y - radius * 3, width: radius * 6, height: radius * 6)),
                             with: .radialGradient(Gradient(colors: [theme.accent2.opacity(0.5 * glow), .clear]),
                                                   center: CGPoint(x: x, y: y), startRadius: 0, endRadius: radius * 3))
            case .graphite:
                // Slow floating dust
                let x = fmod(r1 + time * 0.004 * (0.5 + r3), 1) * size.width + shift.x
                let y = (r2 + 0.03 * sin(time * 0.2 + r1 * 5)) * size.height + shift.y
                dot(&context, CGPoint(x: x, y: y), 0.8 + r3 * 1.4, Color.white.opacity(0.18 + 0.2 * r3))
            }
        }
    }

    private func dot(_ context: inout GraphicsContext, _ center: CGPoint, _ radius: Double, _ color: Color) {
        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                     with: .color(color))
    }
}
