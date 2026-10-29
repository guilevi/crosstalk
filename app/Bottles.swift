// The bottles Settings can turn crosstalk on and off in, by running the
// bundled bottle-setup.sh, so nobody needs a terminal for it.

import AppKit
import Foundation

final class BottleList: ObservableObject {
	static let shared = BottleList()

	struct Bottle: Identifiable, Equatable {
		enum State { case off, on, outdated }
		let path: String
		var state: State
		var id: String { path }
		var name: String { URL(fileURLWithPath: path).lastPathComponent }
	}

	@Published private(set) var bottles: [Bottle] = []
	/// The bottle being set up or removed, if any.
	@Published private(set) var busy: String?
	/// What the last change did, or why it failed.
	@Published private(set) var message: String?

	private let resources = Bundle.main.resourceURL!

	/// Bottles chosen by hand, outside CrossOver's bottle folder.
	private var chosen: [String] {
		get { Preferences.defaults.stringArray(forKey: "chosenBottles") ?? [] }
		set { Preferences.defaults.set(newValue, forKey: "chosenBottles") }
	}

	/// The CrossOver Crosstalk sets bottles up with.
	var crossOver: URL? {
		NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.codeweavers.CrossOver")
	}

	/// Where CrossOver keeps bottles; users can move it in CrossOver's settings.
	var bottleFolder: URL {
		if let dir = UserDefaults(suiteName: "com.codeweavers.CrossOver")?.string(forKey: "BottleDir") {
			return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
		}
		return FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
	}

	func refresh() {
		let fm = FileManager.default
		var paths = Set(chosen + BottleWatcher.shared.activeBottles)
		let folder = bottleFolder
		for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
			paths.insert(folder.appendingPathComponent(name).path)
		}
		bottles = paths.filter(isBottle).sorted {
			$0.localizedStandardCompare($1) == .orderedAscending
		}.map { Bottle(path: $0, state: state(of: $0)) }
	}

	/// Asks for a bottle folder and remembers it.
	func choose() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.treatsFilePackagesAsDirectories = true
		panel.directoryURL = bottleFolder
		panel.message = "Choose a CrossOver bottle folder."
		panel.prompt = "Choose Bottle"
		guard panel.runModal() == .OK, let url = panel.url else { return }
		guard isBottle(url.path) else {
			message = "\(url.lastPathComponent) is not a CrossOver bottle."
			return
		}
		if !chosen.contains(url.path) { chosen.append(url.path) }
		refresh()
	}

	func set(_ bottle: Bottle, on: Bool) {
		guard busy == nil else { return }
		guard let cx = crossOver else {
			message = "CrossOver was not found. Install it, then try again."
			return
		}
		busy = bottle.path
		message = on ? "Turning Crosstalk on in \(bottle.name)…" : "Turning Crosstalk off in \(bottle.name)…"
		let script = resources.appendingPathComponent("bottle-setup.sh")
		let support = cx.appendingPathComponent("Contents/SharedSupport/CrossOver").path
		DispatchQueue.global().async {
			// CrossOver's wine hangs on a bottle Crosstalk may not read, such
			// as one on an external drive before Removable Volumes is allowed.
			let result: (ok: Bool, output: String)
			if !childCanRead("\(bottle.path)/system.reg") {
				result = (false, "Crosstalk can't reach \(bottle.name). If it is on an external drive, allow Crosstalk under Privacy & Security, Files and Folders, Removable Volumes, then try again.")
			} else {
				result = run(script.path, [on ? "install" : "uninstall", bottle.path], env: ["CX": support])
			}
			DispatchQueue.main.async {
				self.busy = nil
				let lines = result.output.split(separator: "\n")
				self.message = result.ok ? lines.last.map(String.init) : "Could not change \(bottle.name): " + (lines.last.map(String.init) ?? "unknown error")
				self.refresh()
				NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested,
				                     userInfo: [.announcement: self.message ?? "", .priority: NSAccessibilityPriorityLevel.high.rawValue])
			}
		}
	}

	private func isBottle(_ path: String) -> Bool {
		FileManager.default.fileExists(atPath: "\(path)/cxbottle.conf")
	}

	/// Off, on, or on with files older than this Crosstalk's or CrossOver's.
	private func state(of path: String) -> Bottle.State {
		let fm = FileManager.default
		let c = "\(path)/drive_c"
		guard fm.fileExists(atPath: "\(path)/\(BottleWatcher.standIn)") else { return .off }
		let win = resources.appendingPathComponent("windows").path
		var same = [
			("\(win)/x64/nvda.exe", "\(path)/\(BottleWatcher.standIn)"),
			("\(win)/x64/uiautomationcore.dll", "\(c)/windows/system32/uiautomationcore.dll"),
		]
		if let cx = crossOver {
			same.append((cx.appendingPathComponent("Contents/SharedSupport/CrossOver/lib/wine/x86_64-windows/uiautomationcore.dll").path,
			             "\(c)/windows/system32/crosstalk_wineuia.dll"))
		}
		return same.allSatisfy { fm.contentsEqual(atPath: $0, andPath: $1) } ? .on : .outdated
	}
}

/// Runs a program to completion, giving up after five minutes.
private func run(_ path: String, _ args: [String], env: [String: String]) -> (ok: Bool, output: String) {
	let p = Process()
	p.executableURL = URL(fileURLWithPath: path)
	p.arguments = args
	p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
	// Output goes to a file rather than a pipe: anything the script leaves
	// running, such as a wineserver it booted, would hold a pipe open.
	let log = FileManager.default.temporaryDirectory.appendingPathComponent("crosstalk-\(UUID().uuidString).log")
	FileManager.default.createFile(atPath: log.path, contents: nil)
	defer { try? FileManager.default.removeItem(at: log) }
	guard let out = try? FileHandle(forWritingTo: log) else { return (false, "could not write \(log.path)") }
	p.standardOutput = out
	p.standardError = out
	p.standardInput = FileHandle.nullDevice
	guard (try? p.run()) != nil else { return (false, "could not run \(path)") }
	let deadline = Date().addingTimeInterval(300)
	while p.isRunning && Date() < deadline { usleep(200_000) }
	if p.isRunning { kill(p.processIdentifier, SIGKILL); p.waitUntilExit() }
	try? out.close()
	let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
	return (p.terminationReason == .exit && p.terminationStatus == 0, text)
}

/// Writes the script a bottle's nvda.exe runs to open Crosstalk when it isn't
/// running, pointing at wherever this copy of the app is.
func writeLauncher() {
	let dir = FileManager.default.homeDirectoryForCurrentUser
		.appendingPathComponent("Library/Application Support/Crosstalk")
	let file = dir.appendingPathComponent("launch-crosstalk")
	let script = """
	#!/bin/sh
	# Run from inside a Wine bottle by crosstalk's nvda.exe when Crosstalk is not
	# running. Wine's start.exe /unix passes no arguments, hence this script.
	exec /usr/bin/open -g -a '\(Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''"))' --args --background

	"""
	guard (try? String(contentsOf: file, encoding: .utf8)) != script else { return }
	try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	try? script.write(to: file, atomically: true, encoding: .utf8)
	try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
}
