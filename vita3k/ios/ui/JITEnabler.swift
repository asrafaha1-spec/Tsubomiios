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
import Network
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
        keepRunningWhileAttaching()
    }

    private static var attachTask = UIBackgroundTaskIdentifier.invalid
    private static var requestedAt = Date()

    /// StikDebug has to be in front to attach, which would put Vita3K to sleep before the debugger arrives.
    /// A short background task keeps Vita3K running, so it notices the debugger and prepares JIT even if
    /// you are slow to come back (or never do).
    private static func keepRunningWhileAttaching() {
        endAttachTask()
        requestedAt = Date()
        attachTask = UIApplication.shared.beginBackgroundTask(withName: "Vita3K JIT attach") {
            MainActor.assumeIsolated {
                v3k_log_ui("JIT: iOS ended the background time before JIT was ready")
                endAttachTask()
            }
        }
        v3k_log_jit_state("Enable JIT tapped")
        var loggedDebugger = false
        func poll() {
            guard attachTask != .invalid else { return }
            let elapsed = Date().timeIntervalSince(requestedAt)
            let ms = Int(elapsed * 1000)
            if v3k_is_jit_enabled() {
                v3k_log_ui("JIT: ready \(ms) ms after Enable JIT")
                endAttachTask()
                return
            }
            if !loggedDebugger && v3k_jit_can_request() {
                loggedDebugger = true
                v3k_log_ui("JIT: the debugger attached \(ms) ms after Enable JIT")
                v3k_log_jit_state("debugger attached")
            }
            if elapsed > 120 {
                v3k_log_ui("JIT: no debugger after 2 minutes")
                v3k_log_jit_state("gave up waiting")
                endAttachTask()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
        }
        poll()
    }

    private static func endAttachTask() {
        guard attachTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(attachTask)
        attachTask = .invalid
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
        // (">>> 0": JavaScript's & gives a signed number, which never equals 0xd4200000)
        const isBrk = ((instruction & 0xffe0001f) >>> 0) === 0xd4200000;
        if (!isBrk || ((instruction >>> 5) & 0xffff) !== 0xf00d) { resume = passOn; continue; }
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

/// Built-in JIT: no JIT app. The player imports their pairing file once; from then on a helper process
/// (the RAM helper extension running StikJIT) attaches the debugger to Hinoki by itself whenever JIT is
/// off, through LocalDevVPN, the same way StikDebug does. Not inside LiveContainer (StikJIT's rule).
@MainActor
final class BuiltinJIT: ObservableObject {
    static let shared = BuiltinJIT()

    @Published private(set) var status = ""
    @Published private(set) var busy = false

    /// Where StikJIT's guide keeps it (Files and Finder can reach Documents)
    static var pairingURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("StikJIT/pairingFile.plist")
    }

    static var hasPairingFile: Bool { FileManager.default.isReadableFile(atPath: pairingURL.path) }

    /// Why it can't run here, nil when it can
    static var unavailableReason: String? {
        guard let reason = v3k_builtin_jit_unavailable_reason() else { return nil }
        return String(cString: reason)
    }

    static var usable: Bool { hasPairingFile && unavailableReason == nil }

    /// Copies the picked file in (atomically) and enables JIT straight away
    func importPairingFile(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            // A pairing file is a property list; anything else is the wrong file
            guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil else {
                status = "That file isn't a pairing file (it should be a .plist or .mobiledevicepairing file)"
                return
            }
            let target = Self.pairingURL
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            v3k_log_ui("Built-in JIT: pairing file imported")
            status = "Pairing file imported"
            if !v3k_is_jit_enabled() { enable() }
        } catch {
            status = "Could not import the pairing file: \(error.localizedDescription)"
        }
    }

    func removePairingFile() {
        try? FileManager.default.removeItem(at: Self.pairingURL)
        status = "Pairing file removed"
    }

    /// At launch (library shown) with JIT off: enable it without being asked
    func enableAtLaunchIfPossible() {
        guard Self.usable, !v3k_is_jit_enabled(), !busy else { return }
        enable()
    }

    func enable() {
        guard !busy else { return }
        if let reason = Self.unavailableReason {
            status = reason
            return
        }
        guard let pairing = try? Data(contentsOf: Self.pairingURL), !pairing.isEmpty else {
            status = "Import your pairing file first"
            return
        }
        busy = true
        status = "Looking for the device (LocalDevVPN)"
        v3k_log_jit_state("built-in JIT started")
        // The device's developer services are found from the app first: iOS only asks for Local Network
        // access from the app, and newer iOS versions move the Remote Pairing port away from 49152
        DeviceTunnel.find { [weak self] found in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    v3k_log_ui("Built-in JIT: \(found.log)")
                    if let port = found.port {
                        self.start(pairing: pairing, port: port)
                    } else {
                        self.finished(ok: false, message: found.problem ?? "LocalDevVPN isn't connected")
                    }
                }
            }
        }
    }

    private func start(pairing: Data, port: UInt16) {
        status = "Starting"
        // Hinoki prepares its JIT memory as soon as the debugger is there (as with StikDebug)
        LibraryHost.watchForJITScript(until: .distantFuture)
        // Same script choice as the StikDebug link: Hinoki's own script on iOS 26 without TXM, StikJIT's
        // universal script where TXM needs one. Before iOS 26 the attach alone enables JIT and Hinoki never
        // sends the script's "done" request, so a script would keep the helper attached: attach and let go
        var script: String?
        var force = false
        if #available(iOS 26.0, *) {
            if !DeviceTXM.present {
                script = Data(JITEnabler.jitScript.utf8).base64EncodedString()
                force = true
            }
        } else {
            script = Data(Self.attachAndDetachScript.utf8).base64EncodedString()
            force = true
        }
        pairing.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress
            if let script {
                script.withCString { v3k_builtin_jit_start(bytes, pairing.count, $0, force, port, builtinJITProgress, builtinJITDone) }
            } else {
                v3k_builtin_jit_start(bytes, pairing.count, nil, force, port, builtinJITProgress, builtinJITDone)
            }
        }
    }

    /// Before iOS 26: what StikJIT does where no script is needed (the attach sets CS_DEBUGGED)
    private static let attachAndDetachScript = #"""
    const pid = get_pid();
    log(`Hinoki JIT: attaching to ${pid}`);
    send_command(`vAttach;${pid.toString(16)}`);
    send_command("D");
    log("Hinoki JIT: attached and detached");
    """#

    fileprivate func update(_ text: String) {
        status = text
    }

    fileprivate func finished(ok: Bool, message: String?) {
        busy = false
        if ok {
            status = "JIT enabled"
        } else {
            let reason = message ?? "unknown error"
            // The usual cause: no route to the device's own developer services
            let lowered = reason.lowercased()
            if reason.hasPrefix("Local Network") || reason.hasPrefix("LocalDevVPN") {
                status = reason
            } else if lowered.contains("unreachable") || lowered.contains("timed out") || lowered.contains("connect") {
                status = "Couldn't reach the device: is LocalDevVPN connected? (\(reason))"
            } else {
                status = "Failed: \(reason)"
            }
        }
        v3k_log_jit_state(ok ? "built-in JIT done" : "built-in JIT failed")
    }
}

/// Finds the device's own Remote Pairing service through LocalDevVPN (10.7.0.1) and checks it answers.
/// The port comes from Bonjour, as StikJIT does it, but only one that really answers on 10.7.0.1 is
/// used: on Wi-Fi other Apple devices advertise the same service, and taking theirs (StikJIT takes the
/// first one found when none is on the loopback) gave a port this iPhone doesn't listen on.
enum DeviceTunnel {
    static let address = "10.7.0.1"
    static let defaultPort: UInt16 = 49152

    struct Found {
        var port: UInt16?
        var problem: String?
        var log: String
    }

    private static let queue = DispatchQueue(label: "hinoki.builtin-jit.tunnel")

    static func find(completion: @escaping (Found) -> Void) {
        queue.async {
            let browsed = browse(timeout: 4)
            var tried: [UInt16] = []
            // the loopback service first (the device's own, through the tunnel), then the usual port, then the rest
            let ordered = browsed.loopback + [defaultPort] + browsed.other
            for port in ordered where !tried.contains(port) {
                tried.append(port)
                if reachable(port: port, timeout: port == defaultPort || browsed.loopback.contains(port) ? 8 : 3) {
                    completion(Found(port: port, problem: nil, log: "device reachable at \(address):\(port) (Bonjour: \(browsed.summary))"))
                    return
                }
            }
            let problem: String
            if browsed.denied {
                problem = "Local Network access is off for Hinoki: turn it on in Settings › Privacy & Security › Local Network, then try again"
            } else {
                problem = "LocalDevVPN isn't connected: open LocalDevVPN, connect it, then try again (nothing answered at \(address))"
            }
            completion(Found(port: nil, problem: problem, log: "device not reachable, tried ports \(tried) (Bonjour: \(browsed.summary))"))
        }
    }

    private struct Browsed {
        var loopback: [UInt16] = []
        var other: [UInt16] = []
        var denied = false
        var summary = "nothing found"
    }

    /// Lists the _remotepairing._tcp services and resolves their ports (iOS asks for Local Network access here)
    private static func browse(timeout: TimeInterval) -> Browsed {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var services: [(endpoint: NWEndpoint, loopback: Bool)] = []
            var denied = false
            var failure: String?
        }
        let state = State()
        let browseQueue = DispatchQueue(label: "hinoki.builtin-jit.browse")
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: "local."), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            state.lock.lock()
            state.services = results.compactMap { result -> (endpoint: NWEndpoint, loopback: Bool)? in
                guard case .service = result.endpoint else { return nil }
                return (endpoint: result.endpoint, loopback: result.interfaces.contains { $0.name.hasPrefix("lo") })
            }
            state.lock.unlock()
        }
        browser.stateUpdateHandler = { browserState in
            var error: NWError?
            switch browserState {
            case .failed(let e): error = e
            case .waiting(let e): error = e
            default: break
            }
            guard let error else { return }
            state.lock.lock()
            state.failure = "\(error)"
            // kDNSServiceErr_PolicyDenied: Local Network access refused
            if case .dns(let code) = error, code == -65570 || code == -65555 { state.denied = true }
            state.lock.unlock()
        }
        browser.start(queue: browseQueue)
        // done early once the device's own (loopback) service shows up, or the browse is refused
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            state.lock.lock()
            let settled = state.denied || state.services.contains { $0.loopback }
            state.lock.unlock()
            if settled { break }
        }
        browser.cancel()

        state.lock.lock()
        let services = state.services
        var result = Browsed()
        result.denied = state.denied
        let failure = state.failure
        state.lock.unlock()

        for service in services.prefix(6) {
            guard let port = resolvePort(service.endpoint, parameters: parameters) else { continue }
            if service.loopback { result.loopback.append(port) } else { result.other.append(port) }
        }
        result.summary = "\(services.count) service(s), loopback ports \(result.loopback), other ports \(result.other)\(failure.map { ", \($0)" } ?? "")"
        return result
    }

    private static func resolvePort(_ endpoint: NWEndpoint, parameters: NWParameters) -> UInt16? {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var port: UInt16?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let connection = NWConnection(to: endpoint, using: parameters)
        let record = { [weak connection] in
            guard let connection, case .hostPort(_, let port) = connection.currentPath?.remoteEndpoint, port.rawValue != 0 else { return }
            box.lock.lock()
            let first = box.port == nil
            box.port = port.rawValue
            box.lock.unlock()
            if first { done.signal() }
        }
        connection.pathUpdateHandler = { path in
            if path.status == .satisfied { record() }
        }
        connection.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .ready, .waiting: record()
            case .failed: done.signal()
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "hinoki.builtin-jit.resolve"))
        _ = done.wait(timeout: .now() + 2)
        connection.cancel()
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.port
    }

    /// A TCP connection to the device's developer services through the tunnel
    private static func reachable(port: UInt16, timeout: TimeInterval) -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var ok = false
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let connection = NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: .tcp)
        connection.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .ready:
                box.lock.lock()
                box.ok = true
                box.lock.unlock()
                done.signal()
            case .failed, .waiting:
                // waiting: no route to 10.7.0.1 (LocalDevVPN off) or the connection was refused
                done.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "hinoki.builtin-jit.probe"))
        _ = done.wait(timeout: .now() + timeout)
        connection.cancel()
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.ok
    }
}

private func builtinJITProgress(_ text: UnsafePointer<CChar>?) {
    guard let text else { return }
    let line = String(cString: text)
    DispatchQueue.main.async { MainActor.assumeIsolated { BuiltinJIT.shared.update(line) } }
}

private func builtinJITDone(_ ok: Bool, _ message: UnsafePointer<CChar>?) {
    let text = message.map { String(cString: $0) }
    DispatchQueue.main.async { MainActor.assumeIsolated { BuiltinJIT.shared.finished(ok: ok, message: text) } }
}

/// Built-in JIT settings: import the pairing file, status, enable now
struct BuiltinJITSection: View {
    @ObservedObject private var jit = BuiltinJIT.shared
    @EnvironmentObject var model: LibraryModel
    @State private var importing = false
    @State private var hasPairing = BuiltinJIT.hasPairingFile

    var body: some View {
        Section {
            if let reason = BuiltinJIT.unavailableReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Pairing file", value: hasPairing ? "Imported" : "None")
                Button(hasPairing ? "Replace pairing file" : "Import pairing file") { importing = true }
                if hasPairing && !model.jitEnabled {
                    Button {
                        jit.enable()
                    } label: {
                        Label(jit.busy ? "Enabling JIT..." : "Enable JIT (built-in)", systemImage: "bolt.fill")
                    }
                    .disabled(jit.busy)
                }
                if !jit.status.isEmpty {
                    Text(jit.status)
                        .font(.footnote)
                }
                if hasPairing {
                    Button("Remove pairing file", role: .destructive) {
                        jit.removePairingFile()
                        hasPairing = BuiltinJIT.hasPairingFile
                    }
                }
            }
        } header: {
            Text("Built-in JIT")
        } footer: {
            Text("No JIT app needed: import your pairing file once (the same file StikDebug uses) and Hinoki enables JIT by itself every time it opens. LocalDevVPN has to be connected, as for StikDebug; the first time, the Developer Disk Image is downloaded and mounted, which takes a minute.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .xml, .data, .item]) { result in
            if case .success(let url) = result {
                jit.importPairingFile(from: url)
                hasPairing = BuiltinJIT.hasPairingFile
            }
        }
        .onChangeCompat(of: jit.busy) { _, busy in
            if !busy { model.reload() }
        }
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
