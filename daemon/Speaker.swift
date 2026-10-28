// The speech engine shared by Crosstalk.app and the headless crosstalkd.
//
// Speech runs through one global queue fed to AVSpeechSynthesizer an utterance
// at a time, so interrupting, queuing and NVDA's speech priorities behave the
// same no matter how many programs are talking. Everything here runs on the
// main queue.

import AVFoundation
import Combine
import Foundation

let VERSION = "0.2.0"

/// How a new utterance relates to what is already speaking or queued.
enum SpeakMode: Int {
	/// Append to the queue (NVDA speakText, UIA NotificationProcessing_All).
	case queue = 0
	/// Cancel everything, then speak (Tolk/Prism interrupt, UIA *MostRecent).
	case interrupt = 1
	/// NVDA SPEECH_PRIORITY_NOW: speak right away; interrupted speech resumes after.
	case now = 2
	/// NVDA SPEECH_PRIORITY_NEXT: speak once the current utterance completes.
	case next = 3
	/// UIA CurrentThenMostRecent: let the current utterance finish, drop the rest.
	case replacePending = 4
}

// MARK: - Preferences

struct Preferences {
	static let defaults = UserDefaults(suiteName: "com.guilevi.crosstalk") ?? .standard

	/// BCP-47 code; nil follows the system language.
	var language: String? { didSet { Self.defaults.set(language, forKey: "language") } }
	/// Voice identifier; nil uses the language's default voice.
	var voice: String? { didSet { Self.defaults.set(voice, forKey: "voice") } }
	var rate: Float { didSet { Self.defaults.set(rate, forKey: "rate") } }
	var volume: Float { didSet { Self.defaults.set(volume, forKey: "volume") } }
	var pitch: Float { didSet { Self.defaults.set(pitch, forKey: "pitch") } }

	init() {
		let d = Self.defaults
		language = d.string(forKey: "language")
		voice = d.string(forKey: "voice")
		rate = d.object(forKey: "rate") as? Float ?? 50
		volume = d.object(forKey: "volume") as? Float ?? 100
		pitch = d.object(forKey: "pitch") as? Float ?? 50
	}
}

// MARK: - Speaker

final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
	static let shared = Speaker()

	struct Item {
		let id: UInt64
		let text: String
		let source: String
		let mode: SpeakMode
	}

	struct Event: Identifiable {
		let id: Int
		let kind: String
		let utterance: UInt64
		let source: String
		let text: String
		var line: String { "\(kind)\t\(utterance)\t\(source)\t\(text)" }
	}

	enum Outcome: String { case done, cancelled }

	/// Called with each history line as it is recorded (crosstalkd -v logs these).
	var onEvent: ((String) -> Void)?

	private let synth = AVSpeechSynthesizer()
	@Published private(set) var settings = Preferences()
	@Published private(set) var history: [Event] = []
	private var queue: [Item] = []
	private var current: (item: Item, utterance: AVSpeechUtterance)?
	private var nextId: UInt64 = 1
	private var serial = 0
	private var waiters: [UInt64: [(Outcome) -> Void]] = [:]
	private var finished: [UInt64: Outcome] = [:]

	override init() {
		super.init()
		synth.delegate = self
	}

	// MARK: Queue

	@discardableResult
	func speak(_ text: String, mode: SpeakMode, source: String) -> UInt64 {
		let item = Item(id: nextId, text: text, source: source, mode: mode)
		nextId += 1
		record("speak", item)

		switch mode {
		case .queue:
			queue.append(item)
		case .interrupt:
			cancelQueued()
			cancelCurrent()
			queue.append(item)
		case .now:
			// Jump ahead of everything; the interrupted utterance restarts
			// afterwards, which is as close to NVDA's resume as AVSpeech allows.
			let insertAt = queue.prefix { $0.mode == .now }.count
			queue.insert(item, at: insertAt)
			if let cur = current, cur.item.mode != .now {
				queue.insert(cur.item, at: insertAt + 1)
				abandonCurrent()
			}
		case .next:
			let insertAt = queue.prefix { $0.mode == .now || $0.mode == .next }.count
			queue.insert(item, at: insertAt)
		case .replacePending:
			cancelQueued()
			queue.append(item)
		}
		pump()
		return item.id
	}

	func stop() {
		cancelQueued()
		cancelCurrent()
	}

	var isSpeaking: Bool { current != nil || !queue.isEmpty }

	/// Calls `done` once the utterance completes or is cancelled.
	func wait(_ id: UInt64, _ done: @escaping (String) -> Void) {
		if let o = finished[id] { return done(o.rawValue) }
		if id == 0 || id >= nextId { return done("unknown") }
		waiters[id, default: []].append { done($0.rawValue) }
	}

	private func pump() {
		guard current == nil, !queue.isEmpty else { return }
		let item = queue.removeFirst()
		// Empty text is how UIA clients (Prism among them) express "stop".
		if item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			complete(item, .done)
			return pump()
		}
		let u = AVSpeechUtterance(string: item.text)
		u.voice = voice()
		u.rate = AVSpeechUtteranceMinimumSpeechRate
			+ (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * settings.rate / 100
		u.volume = settings.volume / 100
		// 0..100 maps to AVSpeech's 0.5..2.0 pitch multiplier, 50 -> 1.0.
		u.pitchMultiplier = settings.pitch <= 50 ? 0.5 + settings.pitch / 100 : 1 + (settings.pitch - 50) / 50
		current = (item, u)
		synth.speak(u)
	}

	private func cancelQueued() {
		let dropped = queue
		queue.removeAll()
		for item in dropped { complete(item, .cancelled) }
	}

	private func cancelCurrent() {
		guard let cur = current else { return }
		abandonCurrent()
		complete(cur.item, .cancelled)
	}

	/// Silences the current utterance without reporting it finished; delegate
	/// callbacks for it arrive later and are ignored because `current` moved on.
	private func abandonCurrent() {
		current = nil
		synth.stopSpeaking(at: .immediate)
	}

	private func complete(_ item: Item, _ outcome: Outcome) {
		record(outcome == .done ? "done" : "cancelled", item)
		finished[item.id] = outcome
		if finished.count > 4096, let oldest = finished.keys.min() { finished[oldest] = nil }
		for w in waiters.removeValue(forKey: item.id) ?? [] { w(outcome) }
	}

	// MARK: AVSpeechSynthesizerDelegate

	func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
		if let cur = current, cur.utterance === u { record("start", cur.item) }
	}

	func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
		guard let cur = current, cur.utterance === u else { return }
		current = nil
		complete(cur.item, .done)
		pump()
	}

	func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
		// Cancellation is always initiated here, which already settled the item.
		// A cancel for the live utterance means the system stopped it for us.
		guard let cur = current, cur.utterance === u else { return }
		current = nil
		complete(cur.item, .cancelled)
		pump()
	}

	// MARK: Voices and settings

	/// All installed voices, sorted by language then name.
	private(set) lazy var allVoices: [AVSpeechSynthesisVoice] =
		AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language, $0.name) < ($1.language, $1.name) }

	var languages: [String] { Array(Set(allVoices.map(\.language))).sorted() }

	/// The language in effect: the chosen one, else the system's.
	var effectiveLanguage: String { settings.language ?? AVSpeechSynthesisVoice.currentLanguageCode() }

	func voices(for language: String) -> [AVSpeechSynthesisVoice] {
		allVoices.filter { $0.language == language }
	}

	/// The chosen voice when it belongs to the chosen language, else that
	/// language's default voice.
	func voice() -> AVSpeechSynthesisVoice? {
		let lang = effectiveLanguage
		if let id = settings.voice, let v = AVSpeechSynthesisVoice(identifier: id), v.language == lang { return v }
		return AVSpeechSynthesisVoice(language: lang) ?? voices(for: lang).first
	}

	func currentVoice() -> String { voice()?.identifier ?? "" }

	/// Choosing a voice also chooses its language.
	func setVoice(_ id: String?) -> Bool {
		guard let id else { settings.voice = nil; return true }
		guard let v = AVSpeechSynthesisVoice(identifier: id) else { return false }
		settings.language = v.language
		settings.voice = id
		return true
	}

	/// nil follows the system language. The voice resets to the new language's
	/// default unless the chosen one already speaks it.
	func setLanguage(_ lang: String?) -> Bool {
		if let lang, !languages.contains(lang) { return false }
		settings.language = lang
		if let id = settings.voice, AVSpeechSynthesisVoice(identifier: id)?.language != effectiveLanguage {
			settings.voice = nil
		}
		return true
	}

	func rate(_ v: Float?) -> Float { if let v { settings.rate = clamp(v) }; return settings.rate }
	func volume(_ v: Float?) -> Float { if let v { settings.volume = clamp(v) }; return settings.volume }
	func pitch(_ v: Float?) -> Float { if let v { settings.pitch = clamp(v) }; return settings.pitch }
	private func clamp(_ v: Float) -> Float { max(0, min(100, v)) }

	// MARK: History

	private func record(_ kind: String, _ item: Item) {
		let flat = item.text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
		serial += 1
		let e = Event(id: serial, kind: kind, utterance: item.id, source: item.source, text: flat)
		onEvent?(e.line)
		history.append(e)
		if history.count > 1000 { history.removeFirst(history.count - 1000) }
	}

	func recentHistory(_ n: Int) -> [String] { history.suffix(max(0, n)).map(\.line) }
}
