// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

/// What the in-game performance overlay shows, and where (Settings › Performance overlay)
enum HUDSettings {
    struct Item: Identifiable {
        let key: String
        let title: String
        let detail: String
        let defaultOn: Bool
        var id: String { key }
    }

    static let items: [Item] = [
        Item(key: "fps", title: "Frame rate", detail: "Frames per second", defaultOn: true),
        Item(key: "frametime", title: "Frame time", detail: "Milliseconds per frame", defaultOn: false),
        Item(key: "minmax", title: "Min / average / max FPS", detail: "Over the last seconds", defaultOn: false),
        Item(key: "cpu", title: "CPU use", detail: "Share of all CPU cores the emulator uses", defaultOn: false),
        Item(key: "memory", title: "Memory", detail: "Used, and left before iOS would close the app", defaultOn: true),
        Item(key: "thermal", title: "Thermal state", detail: "As reported by iOS: Normal, Fair, Serious, Critical", defaultOn: true),
        Item(key: "battery", title: "Battery", detail: "Level and charging", defaultOn: false),
        Item(key: "resolution", title: "Resolution", detail: "Internal rendering resolution", defaultOn: false),
        Item(key: "shaders", title: "New shaders", detail: "Shaders compiled recently (stutter source)", defaultOn: false),
    ]

    static let positions = ["Top left", "Top right", "Bottom left", "Bottom right"]
    static let sizes = ["Small", "Medium", "Large"]

    static var enabled: Bool { UserDefaults.standard.object(forKey: "v3k.hud.enabled") as? Bool ?? false }
    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: "v3k.hud.\(key)") as? Bool ?? items.first { $0.key == key }?.defaultOn ?? false
    }
    static var position: Int { UserDefaults.standard.object(forKey: "v3k.hud.position") as? Int ?? 0 }
    static var size: Int { UserDefaults.standard.object(forKey: "v3k.hud.size") as? Int ?? 1 }
    static var backgroundOpacity: Double { UserDefaults.standard.object(forKey: "v3k.hud.opacity") as? Double ?? 0.35 }
}

private struct PerfSample: Decodable {
    var fps: Int = 0
    var avgFps: Int = 0
    var minFps: Int = 0
    var maxFps: Int = 0
    var frameMs: Int = 0
    var cpu: Double = 0
    var memoryUsed: UInt64 = 0
    var memoryAvailable: UInt64 = 0
    var resolutionScale: Double = 1
    var width: Int = 960
    var height: Int = 544
    var shadersCompiled: Int = 0
}

/// A small transparent panel above the game. It never takes touches.
final class PerformanceHUDView: UIView {
    private let label = UILabel()
    private var timer: Timer?
    let corner = HUDSettings.position

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(HUDSettings.backgroundOpacity)
        layer.cornerRadius = 8
        label.numberOfLines = 0
        let size: CGFloat = [10, 12, 15][min(max(HUDSettings.size, 0), 2)]
        label.font = .monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        label.textColor = .white
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.8
        label.layer.shadowRadius = 1.5
        label.layer.shadowOffset = .zero
        addSubview(label)
        UIDevice.current.isBatteryMonitoringEnabled = HUDSettings.isOn("battery")
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { timer?.invalidate() }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let text = label.sizeThatFits(CGSize(width: 320, height: 400))
        return CGSize(width: text.width + 14, height: text.height + 10)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 7, dy: 5)
    }

    private func update() {
        var sample = PerfSample()
        if let pointer = v3k_perf_json() {
            let json = String(cString: pointer)
            v3k_free_string(pointer)
            if let data = json.data(using: .utf8), let decoded = try? JSONDecoder().decode(PerfSample.self, from: data) {
                sample = decoded
            }
        }

        let text = NSMutableAttributedString()
        func line(_ string: String, color: UIColor = .white) {
            if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(string: string, attributes: [.foregroundColor: color]))
        }
        if HUDSettings.isOn("fps") {
            let color: UIColor = sample.fps >= 28 ? .white : sample.fps >= 20 ? .systemYellow : .systemOrange
            line("\(sample.fps) FPS", color: color)
        }
        if HUDSettings.isOn("frametime") { line("\(sample.frameMs) ms / frame") }
        if HUDSettings.isOn("minmax") { line("\(sample.minFps) / \(sample.avgFps) / \(sample.maxFps)") }
        if HUDSettings.isOn("cpu") {
            let cores = Double(max(ProcessInfo.processInfo.activeProcessorCount, 1))
            line("CPU \(Int((sample.cpu / cores).rounded()))%")
        }
        if HUDSettings.isOn("memory") {
            let used = ByteCountFormatter.string(fromByteCount: Int64(sample.memoryUsed), countStyle: .memory)
            let free = ByteCountFormatter.string(fromByteCount: Int64(sample.memoryAvailable), countStyle: .memory)
            line("RAM \(used) · \(free) left", color: sample.memoryAvailable < 600_000_000 ? .systemOrange : .white)
        }
        if HUDSettings.isOn("thermal") {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: line("Thermal: Normal")
            case .fair: line("Thermal: Fair", color: .systemYellow)
            case .serious: line("Thermal: Serious", color: .systemOrange)
            case .critical: line("Thermal: Critical", color: .systemRed)
            @unknown default: line("Thermal: ?")
            }
        }
        if HUDSettings.isOn("battery") {
            let device = UIDevice.current
            if device.batteryLevel >= 0 {
                let charging = device.batteryState == .charging || device.batteryState == .full
                line("Battery \(Int(device.batteryLevel * 100))%\(charging ? " ⚡︎" : "")")
            }
        }
        if HUDSettings.isOn("resolution") {
            line("\(sample.width)×\(sample.height) (\(sample.resolutionScale.formatted())×)")
        }
        if HUDSettings.isOn("shaders") && sample.shadersCompiled > 0 {
            line("\(sample.shadersCompiled) new shaders", color: .systemYellow)
        }

        label.attributedText = text
        isHidden = text.length == 0
        superview?.setNeedsLayout()
    }
}
