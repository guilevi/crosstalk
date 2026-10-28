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
				Text(app.bottles.isEmpty
					? "No bottle with crosstalk installed is running."
					: "Serving bottles: " + app.bottles.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ") + ".")
					.foregroundStyle(.secondary)
			}

			Section("Recent speech") {
				let spoken = speaker.history.filter { $0.kind == "speak" && !$0.text.isEmpty }.suffix(25).reversed()
				if spoken.isEmpty {
					Text("Nothing yet.").foregroundStyle(.secondary)
				}
				ForEach(Array(spoken)) { e in
					Text(e.text)
						.textSelection(.enabled)
						.help(e.source)
						.accessibilityLabel("\(e.text), from \(e.source)")
				}
			}
		}
		.formStyle(.grouped)
		.frame(minWidth: 460, minHeight: 520)
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
				Slider(value: Binding(get: { Double(value) }, set: { set(Float($0.rounded())) }), in: 0...100, step: 1)
					.accessibilityLabel(label)
					.accessibilityValue("\(Int(value)) percent")
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

func AVSystemLanguage() -> String { AVSpeechSynthesisVoice.currentLanguageCode() }

// MARK: - App

final class AppState: ObservableObject {
	@Published var status = "Starting…"
	@Published var bottles: [String] = []
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
		BottleWatcher.shared.onChange = { [state] in state.bottles = BottleWatcher.shared.activeBottles }
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
		menu.addItem(withTitle: "Stop Speech", action: #selector(stopSpeech), keyEquivalent: "").target = self
		controlItem = menu.addItem(withTitle: "Stop Speech on Control", action: #selector(toggleControl), keyEquivalent: "")
		controlItem.target = self
		menu.addItem(.separator())
		menu.addItem(withTitle: "Quit Crosstalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		statusItem.menu = menu
	}

	func menuWillOpen(_ menu: NSMenu) {
		controlItem.state = ControlKeyMonitor.shared.enabled ? .on : .off
	}

	@objc private func openSettings() { showSettings() }
	@objc private func stopSpeech() { Speaker.shared.stop() }
	@objc private func toggleControl() { ControlKeyMonitor.shared.enabled.toggle() }

	private func showSettings() {
		if window == nil {
			let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(app: state)))
			w.title = "Crosstalk"
			w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
			w.setContentSize(NSSize(width: 520, height: 640))
			w.isReleasedWhenClosed = false
			w.center()
			window = w
		}
		NSApp.activate(ignoringOtherApps: true)
		window?.makeKeyAndOrderFront(nil)
	}
}
