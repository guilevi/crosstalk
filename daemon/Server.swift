// The loopback socket the Windows-side shims talk to.
//
// Wine's Winsock maps onto real BSD sockets, so TCP on 127.0.0.1 is the one
// channel that reliably crosses from a bottle to the host.
//
// Protocol: one UTF-8 line per request and per reply. Text is base64 so it can
// never contain the delimiter. Replies are "OK", "OK <value>", or "ERR <why>".
//
//   PING                   -> OK crosstalkd <version>
//   SPEAK <mode> <base64>  -> OK <id>      mode: see SpeakMode
//   STOP                   -> OK           cancel current and queued speech
//   SPEAKING               -> OK <0|1>
//   WAIT <id> [ms]         -> OK <done|cancelled|unknown|timeout>
//   VOICES                 -> OK <n>, then n lines: <identifier>\t<name>\t<bcp47>
//   VOICE [identifier|-]   -> OK <identifier>   (no argument: query; "-": language default)
//   LANGUAGE [bcp47|-]     -> OK <bcp47>        (no argument: query; "-": system language)
//   RATE [0..100]          -> OK <0..100>       (no argument: query)
//   VOLUME [0..100]        -> OK <0..100>
//   PITCH [0..100]         -> OK <0..100>       (50 is the voice's default)
//   HISTORY [n]            -> OK <n>, then n lines: <event>\t<id>\t<source>\t<text>
//   SOURCE <name>          -> OK           label this connection in HISTORY
//   BOTTLES                -> OK <n>, then n lines: <running|blocked>\t<bottle path>
//   QUIT                   -> OK           close this connection

import Foundation

let PORT: UInt16 = UInt16(ProcessInfo.processInfo.environment["CROSSTALK_PORT"] ?? "") ?? 47655

func writeLine(_ fd: Int32, _ s: String) {
	let data = Array((s + "\n").utf8)
	var off = 0
	while off < data.count {
		let n = data[off...].withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
		if n <= 0 { return }
		off += n
	}
}

func onMain<T>(_ body: @escaping () -> T) -> T {
	if Thread.isMainThread { return body() }
	return DispatchQueue.main.sync(execute: body)
}

final class Connection {
	let fd: Int32
	var source = "client"

	init(fd: Int32) { self.fd = fd }

	/// Handles one request line; returns false to close the connection.
	func handle(_ line: String) -> Bool {
		let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
		let cmd = parts[0].uppercased()
		let arg = parts.count > 1 ? parts[1] : nil
		let speaker = Speaker.shared

		switch cmd {
		case "PING":
			writeLine(fd, "OK crosstalkd \(VERSION)")
		case "SPEAK":
			guard parts.count > 2, let m = Int(parts[1]), let mode = SpeakMode(rawValue: m),
			      let raw = Data(base64Encoded: parts[2]),
			      let text = String(data: raw, encoding: .utf8) else { writeLine(fd, "ERR parse"); break }
			let src = source
			writeLine(fd, "OK \(onMain { speaker.speak(text, mode: mode, source: src) })")
		case "STOP":
			onMain { speaker.stop() }
			writeLine(fd, "OK")
		case "SPEAKING":
			writeLine(fd, "OK \(onMain { speaker.isSpeaking } ? 1 : 0)")
		case "WAIT":
			guard let a = arg, let id = UInt64(a) else { writeLine(fd, "ERR parse"); break }
			let timeout = parts.count > 2 ? Int(parts[2]) ?? -1 : -1
			let sem = DispatchSemaphore(value: 0)
			let lock = NSLock()
			var result = "timeout"
			DispatchQueue.main.async {
				speaker.wait(id) { r in lock.lock(); result = r; lock.unlock(); sem.signal() }
			}
			if timeout < 0 { sem.wait() } else { _ = sem.wait(timeout: .now() + .milliseconds(timeout)) }
			lock.lock(); let r = result; lock.unlock()
			writeLine(fd, "OK \(r)")
		case "VOICES":
			let list = onMain { speaker.allVoices.map { "\($0.identifier)\t\($0.name)\t\($0.language)" } }
			writeLine(fd, "OK \(list.count)")
			for l in list { writeLine(fd, l) }
		case "VOICE":
			if let id = arg, !id.isEmpty {
				guard onMain({ speaker.setVoice(id == "-" ? nil : id) }) else { writeLine(fd, "ERR voice"); break }
			}
			writeLine(fd, "OK \(onMain { speaker.currentVoice() })")
		case "LANGUAGE":
			if let lang = arg, !lang.isEmpty {
				guard onMain({ speaker.setLanguage(lang == "-" ? nil : lang) }) else { writeLine(fd, "ERR language"); break }
			}
			writeLine(fd, "OK \(onMain { speaker.effectiveLanguage })")
		case "RATE", "VOLUME", "PITCH":
			let v = arg.flatMap(Float.init)
			if arg != nil && v == nil { writeLine(fd, "ERR parse"); break }
			let r = onMain { cmd == "RATE" ? speaker.rate(v) : cmd == "VOLUME" ? speaker.volume(v) : speaker.pitch(v) }
			writeLine(fd, "OK \(Int(r.rounded()))")
		case "HISTORY":
			let lines = onMain { speaker.recentHistory(arg.flatMap { Int($0) } ?? 50) }
			writeLine(fd, "OK \(lines.count)")
			for l in lines { writeLine(fd, l) }
		case "BOTTLES":
			let lines = onMain { () -> [String] in
				let w = BottleWatcher.shared
				return w.activeBottles.map { (w.blockedBottles.contains($0) ? "blocked" : "running") + "\t" + $0 }
			}
			writeLine(fd, "OK \(lines.count)")
			for l in lines { writeLine(fd, l) }
		case "SOURCE":
			source = (arg ?? "client").replacingOccurrences(of: "\t", with: " ")
			writeLine(fd, "OK")
		case "QUIT":
			writeLine(fd, "OK")
			return false
		default:
			writeLine(fd, "ERR unknown")
		}
		return true
	}

	func serve() {
		var buf = [UInt8]()
		var chunk = [UInt8](repeating: 0, count: 8192)
		while true {
			let n = read(fd, &chunk, chunk.count)
			if n <= 0 { return }
			buf.append(contentsOf: chunk[0..<n])
			while let nl = buf.firstIndex(of: 0x0A) {
				let line = String(decoding: buf[..<nl], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
				buf.removeSubrange(...nl)
				if !line.isEmpty && !handle(line) { return }
			}
		}
	}
}

enum ServerError: Error, CustomStringConvertible {
	case socket, inUse(UInt16)
	var description: String {
		switch self {
		case .socket: return "could not create a socket"
		case .inUse(let p): return "port \(p) is in use (is Crosstalk already running?)"
		}
	}
}

/// Binds 127.0.0.1:PORT and serves each client on its own thread.
func startServer() throws {
	let listenFd = socket(AF_INET, SOCK_STREAM, 0)
	guard listenFd >= 0 else { throw ServerError.socket }
	var yes: Int32 = 1
	setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

	var addr = sockaddr_in()
	addr.sin_family = sa_family_t(AF_INET)
	addr.sin_port = PORT.bigEndian
	addr.sin_addr.s_addr = UInt32(0x7F000001).bigEndian  // loopback only

	let bound = withUnsafePointer(to: &addr) {
		$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
	}
	if bound != 0 {
		close(listenFd)
		throw ServerError.inUse(PORT)
	}
	listen(listenFd, 16)
	signal(SIGPIPE, SIG_IGN)

	Thread.detachNewThread {
		while true {
			let c = accept(listenFd, nil, nil)
			if c < 0 { continue }
			var one: Int32 = 1
			setsockopt(c, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
			setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
			Thread.detachNewThread {
				Connection(fd: c).serve()
				close(c)
			}
		}
	}
}
