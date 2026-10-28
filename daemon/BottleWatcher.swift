// Starts crosstalk's nvda.exe in every CrossOver bottle as it boots.
//
// CrossOver does not reliably run a bottle's Run keys, so instead this watches
// for wineserver processes: each one belongs to one bottle (its WINEPREFIX),
// and when a new one appears for a bottle with crosstalk installed, nvda.exe is
// launched into it with that wineserver's own CrossOver. nvda.exe keeps itself
// to one instance per bottle, so a launch that races the Run key is harmless.

import Darwin
import Foundation

final class BottleWatcher {
	static let shared = BottleWatcher()

	static let standIn = "drive_c/Program Files/Crosstalk/nvda.exe"

	/// wineserver pids already handled, mapped to their bottle.
	private var seen: [pid_t: String] = [:]
	private var timer: DispatchSourceTimer?
	/// Bottles currently running with crosstalk installed.
	private(set) var activeBottles: [String] = []
	var onChange: (() -> Void)?

	func start() {
		let t = DispatchSource.makeTimerSource(queue: .main)
		t.schedule(deadline: .now(), repeating: 3)
		t.setEventHandler { [weak self] in self?.poll() }
		t.resume()
		timer = t
	}

	private func poll() {
		var live: [pid_t: String] = [:]
		for pid in allPids() {
			// The binary really lives at CrossOver.app/.../CrossOver-Hosted Application/wineserver.
			guard let path = executablePath(pid), path.hasSuffix("/wineserver"),
			      path.contains(".app/Contents/SharedSupport/CrossOver/") else { continue }
			if let prefix = seen[pid] {
				live[pid] = prefix
				continue
			}
			guard let prefix = environment(pid)["WINEPREFIX"] else { continue }
			live[pid] = prefix
			if FileManager.default.fileExists(atPath: "\(prefix)/\(Self.standIn)") {
				// Give the bottle a moment to finish booting before joining it.
				DispatchQueue.main.asyncAfter(deadline: .now() + 2) { launch(in: prefix, wineserver: path) }
			}
		}
		seen = live
		let active = Array(Set(live.values)).filter {
			FileManager.default.fileExists(atPath: "\($0)/\(Self.standIn)")
		}.sorted()
		if active != activeBottles {
			activeBottles = active
			onChange?()
		}
	}
}

/// Runs nvda.exe in the bottle at `prefix` with the CrossOver that owns `wineserver`.
private func launch(in prefix: String, wineserver: String) {
	guard let root = wineserver.range(of: "/SharedSupport/CrossOver/") else { return }
	let wine = String(wineserver[..<root.upperBound]) + "bin/wine"
	let bottle = URL(fileURLWithPath: prefix)
	let p = Process()
	p.executableURL = URL(fileURLWithPath: wine)
	p.arguments = ["--bottle", bottle.lastPathComponent, "--cx-app", "C:\\Program Files\\Crosstalk\\nvda.exe"]
	var env = ProcessInfo.processInfo.environment
	env["CX_BOTTLE_PATH"] = bottle.deletingLastPathComponent().path
	p.environment = env
	p.standardOutput = FileHandle.nullDevice
	p.standardError = FileHandle.nullDevice
	guard (try? p.run()) != nil else { return }
	// CrossOver's wrapper returns once nvda.exe is started. If it is still
	// around after a minute it is stuck (on a bottle lock, or waiting for the
	// removable-volume permission); don't let those pile up.
	DispatchQueue.main.asyncAfter(deadline: .now() + 60) { if p.isRunning { p.terminate() } }
}

// MARK: - Process inspection

private func allPids() -> [pid_t] {
	let n = proc_listallpids(nil, 0)
	guard n > 0 else { return [] }
	var pids = [pid_t](repeating: 0, count: Int(n) + 64)
	let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
	return got > 0 ? Array(pids.prefix(Int(got))) : []
}

private func executablePath(_ pid: pid_t) -> String? {
	var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
	guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
	return String(cString: buf)
}

/// Another process's environment, from KERN_PROCARGS2: argc, the executable
/// path, argv, then the environment, all NUL-separated.
private func environment(_ pid: pid_t) -> [String: String] {
	var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
	var size = 0
	guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
	var buf = [UInt8](repeating: 0, count: size)
	guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [:] }
	let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
	var strings: [String] = []
	var i = MemoryLayout<Int32>.size
	var start = -1
	while i < size {
		if buf[i] == 0 {
			if start >= 0 {
				strings.append(String(decoding: buf[start..<i], as: UTF8.self))
				start = -1
			}
		} else if start < 0 {
			start = i
		}
		i += 1
	}
	if start >= 0 { strings.append(String(decoding: buf[start..<size], as: UTF8.self)) }
	// strings[0] is the executable path, then argc arguments, then KEY=VALUE.
	var env: [String: String] = [:]
	for s in strings.dropFirst(1 + Int(argc)) {
		guard let eq = s.firstIndex(of: "=") else { continue }
		env[String(s[..<eq])] = String(s[s.index(after: eq)...])
	}
	return env
}
