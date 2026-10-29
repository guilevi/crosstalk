// Crosstalk.app - the speech server plus a menu-bar item and settings window.
//
// Runs as an agent (no Dock icon). Opening the app again, or choosing
// Settings from its menu-bar item, brings up the settings window.

import AVFoundation
import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

// MARK: - Control key

/// Stops speech whenever Control goes down, in any app, as NVDA does.
/// Seeing other apps' key events needs the Accessibility permission.
final class ControlKeyMonitor: ObservableObject {
	static let shared = ControlKeyMonitor()

	@Published var enabled: Bool {
		didSet {
			Preferences.defaults.set(enabled, forKey: "stopOnControl")
			install()
		}
	}
	@Published private(set) var trusted = AXIsProcessTrusted()

	private var global: Any?
	private var local: Any?
	private var controlDown = false
	private var trustTimer: Timer?

	init() {
		enabled = Preferences.defaults.object(forKey: "stopOnControl") as? Bool ?? true
	}

	func start() {
		install()
		// A global monitor added before the permission is granted never
		// receives anything, so re-add it once the grant shows up.
		trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
			guard let self else { return }
			let now = AXIsProcessTrusted()
			if now != self.trusted {
				self.trusted = now
				self.install()
			}
		}
	}

	func requestPermission() {
		let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
		trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
		if !trusted {
			NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
		}
	}

	private func install() {
		if let g = global { NSEvent.removeMonitor(g); global = nil }
		if let l = local { NSEvent.removeMonitor(l); local = nil }
		guard enabled else { return }
		global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.handle($0) }
		local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] in self?.handle($0); return $0 }
	}

	private func handle(_ e: NSEvent) {
		let down = e.modifierFlags.contains(.control)
		if down && !controlDown { Speaker.shared.stop() }
		controlDown = down
	}
}

// MARK: - Settings window

struct SettingsView: View {
	@ObservedObject var speaker = Speaker.shared
	@ObservedObject var control = ControlKeyMonitor.shared
	@ObservedObject var app: AppState
	@ObservedObject var bottleList = BottleList.shared

	var body: some View {
		Form {
			Section("Voice") {
				Picker("Language", selection: languageBinding) {
					Text("System language (\(languageName(AVSystemLanguage())))").tag("")
					ForEach(speaker.languages, id: \.self) { lang in
						Text(languageName(lang)).tag(lang)
					}
				}
				Picker("Voice", selection: voiceBinding) {
					Text("Default for language").tag("")
					ForEach(speaker.voices(for: speaker.effectiveLanguage), id: \.identifier) { v in
						Text(voiceName(v)).tag(v.identifier)
					}
				}
				percentSlider("Rate", value: speaker.settings.rate) { _ = speaker.rate($0) }
				percentSlider("Volume", value: speaker.settings.volume) { _ = speaker.volume($0) }
				percentSlider("Pitch", value: speaker.settings.pitch) { _ = speaker.pitch($0) }
				Button("Test Speech") {
					speaker.speak("This is how programs in your bottles will sound.", mode: .interrupt, source: "settings")
				}
			}

			Section("Bottles") {
				if bottleList.crossOver == nil {
					Text("CrossOver was not found. Crosstalk works in CrossOver bottles, so install CrossOver first.")
						.foregroundStyle(.secondary)
				}
				if bottleList.bottles.isEmpty {
					Text("No bottles found in \(bottleList.bottleFolder.path).").foregroundStyle(.secondary)
				}
				ForEach(bottleList.bottles) { b in
					HStack {
						Toggle(isOn: Binding(get: { b.state != .off }, set: { bottleList.set(b, on: $0) })) {
							Text(b.name)
							Text(bottleStatus(b)).foregroundStyle(.secondary)
						}
						.accessibilityLabel("\(b.name), \(bottleStatus(b))")
						if b.state == .outdated {
							Button("Update") { bottleList.set(b, on: true) }
								.accessibilityLabel("Update \(b.name)")
						}
					}
					.disabled(bottleList.busy != nil)
				}
				Button("Choose Another Bottle…") { bottleList.choose() }
					.disabled(bottleList.busy != nil)
				if let m = bottleList.message {
					HStack {
						if bottleList.busy != nil { ProgressView().controlSize(.small) }
						Text(m).foregroundStyle(.secondary)
					}
				}
			}

			Section("Interrupting") {
				Toggle("Stop speech when Control is pressed", isOn: $control.enabled)
				if control.enabled && !control.trusted {
					Text("Crosstalk needs the Accessibility permission to notice Control while other apps are in front.")
						.foregroundStyle(.secondary)
					Button("Grant Accessibility Permission…") { control.requestPermission() }
				}
			}

			Section("General") {
				Toggle("Open Crosstalk at login", isOn: $app.openAtLogin)
				Text(app.status).foregroundStyle(.secondary)
				if !app.blockedBottles.isEmpty {
					Text("Crosstalk can't reach " + app.blockedBottles.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
						+ " on its external drive, so it can't start NVDA there itself. Allow Crosstalk under Privacy & Security, Files and Folders, Removable Volumes. Until then the bottle starts it on its own when it can.")
					Button("Open Privacy Settings…") {
						NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
					}
				}
			}

			Section("Recent speech") {
				SpeechTable(events: spoken).frame(minHeight: 200)
			}
		}
		.formStyle(.grouped)
		.frame(minWidth: 460, minHeight: 520)
	}

	/// Spoken text, newest first.
	private var spoken: [Speaker.Event] {
		speaker.history.filter { $0.kind == "speak" && !$0.text.isEmpty }.suffix(100).reversed()
	}

	private func bottleStatus(_ b: BottleList.Bottle) -> String {
		if bottleList.busy == b.path { return "Working…" }
		switch b.state {
		case .off: return "Crosstalk off"
		case .on: return app.bottles.contains(b.path) ? "Crosstalk on, running" : "Crosstalk on"
		case .outdated: return "Crosstalk on, needs an update"
		}
	}

	private var languageBinding: Binding<String> {
		Binding(get: { speaker.settings.language ?? "" },
		        set: { _ = speaker.setLanguage($0.isEmpty ? nil : $0) })
	}

	private var voiceBinding: Binding<String> {
		Binding(get: {
			guard let id = speaker.settings.voice, speaker.voice()?.identifier == id else { return "" }
			return id
		}, set: { _ = speaker.setVoice($0.isEmpty ? nil : $0) })
	}

	private func percentSlider(_ label: String, value: Float, set: @escaping (Float) -> Void) -> some View {
		LabeledContent(label) {
			HStack {
				PercentSlider(label: label, value: value, set: set)
				Text("\(Int(value))").monospacedDigit().frame(width: 32, alignment: .trailing)
					.accessibilityHidden(true)
			}
		}
	}

	private func languageName(_ code: String) -> String {
		let name = Locale.current.localizedString(forIdentifier: code) ?? code
		return "\(name) (\(code))"
	}

	private func voiceName(_ v: AVSpeechSynthesisVoice) -> String {
		switch v.quality {
		case .premium: return "\(v.name) (Premium)"
		case .enhanced: return "\(v.name) (Enhanced)"
		default: return v.name
		}
	}
}

/// A 0-100 slider that moves by 1 with the arrow keys, 5 with Page Up and
/// Page Down, and to either end with Home and End. SwiftUI's Slider only
/// takes the arrows.
struct PercentSlider: NSViewRepresentable {
	let label: String
	let value: Float
	let set: (Float) -> Void

	final class View: NSSlider {
		var onChange: ((Float) -> Void)?

		func step(to v: Double) {
			doubleValue = max(minValue, min(maxValue, v.rounded()))
			describe()
			onChange?(Float(doubleValue))
		}

		func describe() { setAccessibilityValueDescription("\(Int(doubleValue)) percent") }

		override func keyDown(with e: NSEvent) {
			switch Int(e.keyCode) {
			case 116: step(to: doubleValue + 5)            // Page Up
			case 121: step(to: doubleValue - 5)            // Page Down
			case 115: step(to: minValue)                   // Home
			case 119: step(to: maxValue)                   // End
			case 123, 125: step(to: doubleValue - 1)       // Left, Down
			case 124, 126: step(to: doubleValue + 1)       // Right, Up
			default: super.keyDown(with: e)
			}
		}

		override func accessibilityPerformIncrement() -> Bool { step(to: doubleValue + 1); return true }
		override func accessibilityPerformDecrement() -> Bool { step(to: doubleValue - 1); return true }

		@objc func moved() { step(to: doubleValue) }
	}

	func makeNSView(context: Context) -> View {
		let s = View()
		s.minValue = 0
		s.maxValue = 100
		s.target = s
		s.action = #selector(View.moved)
		s.setAccessibilityLabel(label)
		return s
	}

	func updateNSView(_ s: View, context: Context) {
		s.onChange = set
		if s.doubleValue != Double(value) { s.doubleValue = Double(value) }
		s.describe()
	}
}

/// Recent speech as an AppKit table. SwiftUI's Table reaches VoiceOver as an
/// outline without column names.
struct SpeechTable: NSViewRepresentable {
	let events: [Speaker.Event]

	final class TableView: NSTableView {
		var events: [Speaker.Event] = []

		/// Copy puts the selected rows' text on the pasteboard.
		@objc func copy(_ sender: Any?) {
			let text = selectedRowIndexes.map { events[$0].text }.joined(separator: "\n")
			guard !text.isEmpty else { return }
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(text, forType: .string)
		}
	}

	final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
		var events: [Speaker.Event] = []
		let time = DateFormatter()

		override init() { time.timeStyle = .medium }

		func numberOfRows(in t: NSTableView) -> Int { events.count }

		func tableView(_ t: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
			guard let column else { return nil }
			let e = events[row]
			let cell = t.makeView(withIdentifier: column.identifier, owner: nil) as? NSTextField
				?? { let f = NSTextField(labelWithString: ""); f.identifier = column.identifier; f.lineBreakMode = .byTruncatingTail; return f }()
			switch column.identifier.rawValue {
			case "text": cell.stringValue = e.text; cell.toolTip = e.text
			case "source": cell.stringValue = e.source
			default: cell.stringValue = time.string(from: e.time)
			}
			return cell
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeNSView(context: Context) -> NSScrollView {
		let t = TableView()
		for (id, title, width) in [("text", "Text", 260.0), ("source", "Program", 110.0), ("time", "Time", 80.0)] {
			let c = NSTableColumn(identifier: .init(id))
			c.title = title
			c.width = width
			t.addTableColumn(c)
		}
		t.allowsMultipleSelection = true
		t.usesAlternatingRowBackgroundColors = true
		t.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
		t.dataSource = context.coordinator
		t.delegate = context.coordinator
		t.setAccessibilityLabel("Recent speech")
		let scroll = NSScrollView()
		scroll.documentView = t
		scroll.hasVerticalScroller = true
		scroll.borderType = .bezelBorder
		return scroll
	}

	func updateNSView(_ scroll: NSScrollView, context: Context) {
		guard let t = scroll.documentView as? TableView,
		      context.coordinator.events.map(\.id) != events.map(\.id) else { return }
		// Keep the selection on the same entries as new ones arrive on top.
		let selected = Set(t.selectedRowIndexes.map { t.events[$0].id })
		context.coordinator.events = events
		t.events = events
		t.reloadData()
		t.selectRowIndexes(IndexSet(events.indices.filter { selected.contains(events[$0].id) }), byExtendingSelection: false)
	}
}

func AVSystemLanguage() -> String { AVSpeechSynthesisVoice.currentLanguageCode() }

// MARK: - App

final class AppState: ObservableObject {
	@Published var status = "Starting…"
	@Published var bottles: [String] = []
	@Published var blockedBottles: [String] = []
	@Published var openAtLogin: Bool = SMAppService.mainApp.status == .enabled {
		didSet {
			guard openAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
			do {
				if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
			} catch {
				status = "Could not change login item: \(error.localizedDescription)"
				openAtLogin = SMAppService.mainApp.status == .enabled
			}
		}
	}
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
	private let state = AppState()
	private var statusItem: NSStatusItem!
	private var window: NSWindow?
	private var controlItem: NSMenuItem!

	static func main() {
		let app = NSApplication.shared
		let delegate = AppDelegate()
		app.delegate = delegate
		app.setActivationPolicy(.accessory)
		app.run()
	}

	func applicationDidFinishLaunching(_ note: Notification) {
		do {
			try startServer()
			state.status = "Listening for Windows programs on 127.0.0.1:\(PORT)."
		} catch {
			state.status = "Not serving speech: \(error)."
		}
		_ = Speaker.shared
		ControlKeyMonitor.shared.start()
		writeLauncher()
		BottleWatcher.shared.onChange = { [state] in
			state.bottles = BottleWatcher.shared.activeBottles
			state.blockedBottles = BottleWatcher.shared.blockedBottles
			BottleList.shared.refresh()
		}
		BottleWatcher.shared.start()
		buildMenu()

		// Programs only get speech while this runs, so open at login unless
		// the user later turns that off.
		let firstRun = !Preferences.defaults.bool(forKey: "launchedBefore")
		if firstRun {
			Preferences.defaults.set(true, forKey: "launchedBefore")
			state.openAtLogin = true
		}

		// Show settings when launched by hand; not at login, nor when a
		// bottle's nvda.exe started us (--background) mid-game.
		let background = CommandLine.arguments.contains("--background")
		if firstRun || (!background && !isLoginLaunch()) {
			showSettings()
		}
	}

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
		showSettings()
		return true
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

	private func isLoginLaunch() -> Bool {
		// Login items are launched with this Apple Event; a Finder or `open` launch is not.
		guard let e = NSAppleEventManager.shared().currentAppleEvent else { return false }
		return e.eventID == kAEOpenApplication
			&& e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
	}

	private func buildMenu() {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Crosstalk")
		let menu = NSMenu()
		menu.delegate = self
		menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
		controlItem = menu.addItem(withTitle: "Stop Speech on Control", action: #selector(toggleControl), keyEquivalent: "")
		controlItem.target = self
		menu.addItem(.separator())
		menu.addItem(withTitle: "Quit Crosstalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		statusItem.menu = menu

		// The menu bar shown while settings are open, mostly for its shortcuts.
		let main = NSMenu()
		let appMenu = NSMenu()
		appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
		appMenu.addItem(.separator())
		appMenu.addItem(withTitle: "Hide Crosstalk", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
		appMenu.addItem(.separator())
		appMenu.addItem(withTitle: "Quit Crosstalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		let editMenu = NSMenu(title: "Edit")
		editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
		editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
		editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
		editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
		let windowMenu = NSMenu(title: "Window")
		windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
		windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
		for sub in [appMenu, editMenu, windowMenu] {
			main.addItem(withTitle: sub.title, action: nil, keyEquivalent: "").submenu = sub
		}
		NSApp.mainMenu = main
		NSApp.windowsMenu = windowMenu
	}

	func menuWillOpen(_ menu: NSMenu) {
		controlItem.state = ControlKeyMonitor.shared.enabled ? .on : .off
	}

	@objc private func openSettings() {
		// Wait for the status menu to finish closing; activating while it
		// tracks leaves the window behind whatever app was in front.
		DispatchQueue.main.async { self.showSettings() }
	}
	@objc private func toggleControl() { ControlKeyMonitor.shared.enabled.toggle() }

	private func showSettings() {
		BottleList.shared.refresh()
		if window == nil {
			let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
			                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
			                 backing: .buffered, defer: false)
			w.contentView = NSHostingView(rootView: SettingsView(app: state))
			w.title = "Crosstalk"
			w.isReleasedWhenClosed = false
			// Open on whichever Space the user is on, not the one it last used.
			w.collectionBehavior = [.moveToActiveSpace]
			w.delegate = self
			w.center()
			window = w
		}
		// A menu-bar-only app can't reliably take focus, which leaves the window
		// out of reach of VoiceOver and Command-Tab. Be a regular app while
		// settings are open.
		NSApp.setActivationPolicy(.regular)
		// Cooperative activation is refused when the request comes from the
		// status menu rather than from an app the user was in, so insist.
		NSApp.activate(ignoringOtherApps: true)
		window?.makeKeyAndOrderFront(nil)
		window?.orderFrontRegardless()
	}

	func windowWillClose(_ note: Notification) {
		NSApp.setActivationPolicy(.accessory)
	}
}
