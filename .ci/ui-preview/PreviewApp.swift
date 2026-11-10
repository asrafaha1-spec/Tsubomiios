// UI preview harness (CI only): shows the PS Vita home screen in fixed states with fake games, so
// changes to it can be looked at in the iOS simulator before they ship. Not part of the app.

import SwiftUI
import UIKit

@main
struct PreviewApp: App {
    @StateObject private var model = LibraryModel()
    private let scenario: String
    private let apps: [GameApp]

    init() {
        let args = ProcessInfo.processInfo.arguments
        scenario = args.firstIndex(of: "-scenario").map { args[$0 + 1] } ?? "home"
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "v3k.vitaHome")
        defaults.set(scenario == "lock", forKey: "v3k.vitaHome.lockScreen")
        defaults.set(scenario.hasPrefix("theme:") ? "style." + scenario.dropFirst(6) : "default", forKey: "v3k.vitaHome.theme")
        apps = PreviewApp.makeApps(count: scenario == "many" ? 23 : 8)
    }

    var body: some Scene {
        WindowGroup {
            VitaHomeView(apps: apps, onLaunch: { _ in }, onDetails: { _ in }, onDelete: { _ in }, onDeleteSave: { _ in },
                         onImportFiles: {}, onImportFolder: {}, onEnterZrif: {}, preview: scenario)
                .environmentObject(model)
                .onAppear {
                    if scenario == "themechange" {
                        // The bug this guards against: changing the theme while the home screen is up
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            UserDefaults.standard.set("style.meadow", forKey: "v3k.vitaHome.theme")
                        }
                    }
                }
        }
    }

    static func makeApps(count: Int) -> [GameApp] {
        let names = ["Gravity Rush", "LittleBigPlanet PlayStation Vita", "Danganronpa Another Episode: Ultra Despair Girls",
                     "Danganronpa 2: Goodbye Despair", "Minecraft: PlayStation Vita Edition", "Netflix", "Stardew Valley",
                     "Persona 4 Golden", "Killzone Mercenary", "Uncharted: Golden Abyss", "Tearaway", "WipEout 2048"]
        let colors: [UIColor] = [.systemTeal, .systemPurple, .systemPink, .systemRed, .systemGreen, .systemOrange, .systemBlue, .systemYellow]
        let root = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/vita/ux0/app")
        return (0..<count).map { i in
            let id = String(format: "PCSA%05d", 100 + i)
            let folder = (root as NSString).appendingPathComponent(id)
            try? FileManager.default.createDirectory(atPath: folder + "/sce_sys", withIntermediateDirectories: true)
            let color = colors[i % colors.count]
            let icon = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { ctx in
                color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
                (id.suffix(3) as NSString).draw(at: CGPoint(x: 30, y: 44), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 34), .foregroundColor: UIColor.white])
            }
            let iconPath = folder + "/sce_sys/icon0.png"
            try? icon.pngData()?.write(to: URL(fileURLWithPath: iconPath))
            if i % 2 == 0 {
                let pic = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 544)).image { ctx in
                    color.withAlphaComponent(0.8).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 960, height: 544))
                    UIColor.white.withAlphaComponent(0.3).setFill(); ctx.cgContext.fillEllipse(in: CGRect(x: 520, y: 80, width: 380, height: 380))
                }
                try? pic.pngData()?.write(to: URL(fileURLWithPath: folder + "/sce_sys/pic0.png"))
            }
            return GameApp(titleId: id, title: names[i % names.count], version: "01.00", category: "gd", iconPath: iconPath, path: id,
                           lastPlayed: Int64(Date().timeIntervalSince1970) - Int64(i * 3600), playTime: Int64(i * 2700), customConfig: false,
                           compat: i % 7, compatIssue: 0)
        }
    }
}
