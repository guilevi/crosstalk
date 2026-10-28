// crosstalkd - headless Crosstalk: the speech server without the app's UI.
// Useful over SSH or for testing; Crosstalk.app is the normal way to run it.

import Foundation

if CommandLine.arguments.contains("-v") {
	Speaker.shared.onEvent = { FileHandle.standardError.write("crosstalkd: \($0)\n".data(using: .utf8)!) }
}

do {
	try startServer()
} catch {
	FileHandle.standardError.write("crosstalkd: \(error)\n".data(using: .utf8)!)
	exit(0)
}
_ = Speaker.shared
BottleWatcher.shared.start()
CFRunLoopRun()
