// Vita3K project
// Copyright (C) 2026 Vita3K team
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

import Metal
import SwiftUI
import UIKit

/// One tap to enable JIT: opens the JIT app with Vita3K's bundle ID (or, inside LiveContainer, its
/// process ID) and, where StikDebug needs one, Vita3K's own JIT script, so nobody has to assign a script
/// by hand. The links follow MeloNX's JIT enabler (Stossy11). Vita3K notices the debugger by itself and
/// prepares JIT as soon as it attaches (LibraryHost.watchForJITScript).
enum JITProvider: String, CaseIterable, Identifiable {
    case stikDebug = "StikDebug"
    case stosDebug = "StosDebug"
    case trollStore = "TrollStore"

    var id: String { rawValue }

    /// The URL scheme the app answers to (listed in LSApplicationQueriesSchemes)
    private var scheme: String {
        switch self {
        case .stikDebug: "stikjit"
        case .stosDebug: "stosdebug"
        case .trollStore: "apple-magnifier"
        }
    }

    var isInstalled: Bool {
        guard let url = URL(string: scheme + "://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// The JIT apps found on this device; StikDebug always (iOS can hide other apps' schemes)
    static var available: [JITProvider] {
        let found = allCases.filter { $0.isInstalled }
        return found.contains(.stikDebug) ? found : [.stikDebug] + found
    }
}

@MainActor
enum JITEnabler {
    static var inLiveContainer: Bool {
        ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil || Bundle.main.bundlePath.contains("LiveContainer")
    }

    private static var bundleId: String { Bundle.main.bundleIdentifier ?? "org.vita3k.ios" }

    static func enable(with provider: JITProvider) {
        let pid = getpid()
        var link: String
        switch provider {
        case .stikDebug:
            link = "stikjit://enable-jit"
            link += inLiveContainer ? "?pid=\(pid)" : "?bundle-id=\(bundleId)"
            // iOS 26 on a chip without TXM needs the script passed in; with TXM StikDebug uses its own
            if #available(iOS 26.0, *), !DeviceTXM.present {
                let data = Data(jitScript.utf8).base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                link += "&script-name=Vita3K&script-data=\(data)"
            }
        case .stosDebug:
            link = "stosdebug://enableJIT?bundleId=\(bundleId)&appName=Vita3K&pid=\(pid)"
        case .trollStore:
            link = "apple-magnifier://enable-jit?bundle-id=\(bundleId)"
        }
        guard var url = URL(string: link) else { return }
        // Inside LiveContainer, links to other apps go out through LiveContainer itself
        if inLiveContainer, provider != .trollStore {
            let wrapped = Data(link.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            if let lc = URL(string: "livecontainer://open-web-page?url=\(wrapped)") { url = lc }
        }
        v3k_log_ui("JIT: asking \(provider.rawValue) to enable JIT\(inLiveContainer ? " (via LiveContainer)" : "")")
        UIApplication.shared.open(url) { opened in
            if !opened {
                v3k_log_ui("JIT: \(provider.rawValue) could not be opened")
            }
        }
        // Whatever happens next (StikDebug relaunches Vita3K or attaches to it), watch for the debugger
        LibraryHost.watchForJITScript(until: .distantFuture)
    }

    /// Vita3K's JIT script for StikDebug, written for Vita3K. It speaks the "universal" protocol
    /// Vita3K's JIT uses: `brk #0xf00d` with x16 = 1 asks for an executable region (x0 = address or 0,
    /// x1 = size; the region's address comes back in x0) and x16 = 0 lets the debugger go.
    static let jitScript = #"""
    const pid = get_pid();
    log(`Vita3K JIT: attaching to ${pid}`);
    send_command(`vAttach;${pid.toString(16)}`);

    function littleEndian(hex) {
        let value = 0n;
        for (let i = hex.length - 2; i >= 0; i -= 2) value = (value << 8n) | BigInt(parseInt(hex.substr(i, 2), 16));
        return value;
    }
    function toLittleEndian(value) {
        let hex = "";
        for (let i = 0; i < 8; i++) { hex += Number(value & 0xffn).toString(16).padStart(2, "0"); value >>= 8n; }
        return hex;
    }
    function register(reply, number) {
        const match = new RegExp(`(?:^T[0-9a-f]{2}|;)${number}:([0-9a-f]{16});`).exec(reply);
        return match ? littleEndian(match[1]) : null;
    }

    let resume = "c";
    for (;;) {
        const reply = send_command(resume);
        resume = "c";
        if (!reply || reply[0] === "W" || reply[0] === "X") break; // Vita3K exited
        if (reply[0] !== "T") continue;
        const signal = parseInt(reply.substr(1, 2), 16);
        const thread = (/thread:([0-9a-f]+);/.exec(reply) || [])[1];
        const pc = register(reply, "20");
        // Anything that isn't a JIT request goes back to Vita3K as its signal (it handles its own
        // memory faults and crash reports), so the same stop doesn't repeat forever
        const passOn = `C${signal.toString(16).padStart(2, "0")}`;
        if (signal !== 5 || !thread || pc === null) { resume = passOn; continue; }
        const word = send_command(`m${pc.toString(16)},4`) || "";
        const bytes = word.match(/../g);
        const instruction = bytes && bytes.length === 4 ? parseInt(bytes.reverse().join(""), 16) >>> 0 : 0;
        if ((instruction & 0xffe0001f) !== 0xd4200000 || ((instruction >>> 5) & 0xffff) !== 0xf00d) { resume = passOn; continue; }
        send_command(`P20=${toLittleEndian(pc + 4n)};thread:${thread};`);
        const command = register(reply, "10");
        if (command === 0n) {
            send_command("D");
            log("Vita3K JIT: done, detached");
            break;
        }
        if (command === 1n) {
            const size = register(reply, "01");
            let address = register(reply, "00");
            if (address === 0n) {
                const allocated = send_command(`_M${size.toString(16)},rx`);
                if (!allocated) { log("Vita3K JIT: could not allocate a region"); continue; }
                address = BigInt(`0x${allocated}`);
            }
            prepare_memory_region(address, size);
            send_command(`P0=${toLittleEndian(address)};thread:${thread};`);
        }
    }
    """#
}

/// Whether the chip has Apple's Trusted Execution Monitor, which changes how JIT is enabled on iOS 26.
/// Same checks as MeloNX: the TXM firmware file where it can be seen, otherwise the chip generation.
enum DeviceTXM {
    static let present: Bool = {
        if ProcessInfo.processInfo.isiOSAppOnMac { return false }
        let chip = chipGeneration
        if #available(iOS 27.0, *) {
            guard let chip else { return true }
            return chip.series == "M" || chip.number > 12
        }
        let classic = firmwareFile ?? false
        if #available(iOS 26.6, *), !classic, let chip {
            return chip.series == "M" ? chip.number >= 2 : chip.number >= 15
        }
        return classic
    }()

    /// "A" or "M" and the chip number, from the GPU's name ("Apple A17 Pro GPU")
    private static var chipGeneration: (series: String, number: Int)? {
        guard let name = MTLCreateSystemDefaultDevice()?.name.uppercased(),
              let regex = try? NSRegularExpression(pattern: #"APPLE\s+([MA])(\d+)"#),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let series = Range(match.range(at: 1), in: name), let digits = Range(match.range(at: 2), in: name),
              let number = Int(name[digits]) else { return nil }
        return (String(name[series]), number)
    }

    /// nil when the firmware folder can't be read
    private static var firmwareFile: Bool? {
        func folder(_ path: String, length: Int) -> String? {
            guard let name = (try? FileManager.default.contentsOfDirectory(atPath: path))?.first(where: { $0.count == length }) else { return nil }
            return path + "/" + name
        }
        let txm = "/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4"
        if let boot = folder("/System/Volumes/Preboot", length: 36), let root = folder(boot + "/boot", length: 96) {
            return access(root + txm, F_OK) == 0
        }
        if let root = folder("/private/preboot", length: 96) {
            return access(root + txm, F_OK) == 0
        }
        return nil
    }
}

/// Buttons that enable JIT with each JIT app found on the device
struct EnableJITButtons: View {
    var body: some View {
        ForEach(JITProvider.available) { provider in
            Button {
                JITEnabler.enable(with: provider)
            } label: {
                Label(JITProvider.available.count == 1 ? "Enable JIT" : "Enable JIT with \(provider.rawValue)", systemImage: "bolt.fill")
            }
        }
    }
}
