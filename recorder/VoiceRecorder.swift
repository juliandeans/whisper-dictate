// VoiceRecorder - a minimal, headless CLI microphone recorder.
//
// Usage: VoiceRecorder <wav-path> <log-path> <pid-path>
//
// Records Linear PCM audio (16 kHz, mono, 16-bit, little-endian) to
// <wav-path> using AVAudioRecorder. Writes its own PID to <pid-path> as
// soon as it starts, then appends "recording started" to <log-path> once
// recording has actually begun. On SIGINT or SIGTERM it stops the
// recording cleanly, finalizes the WAV file, removes the PID file, and
// exits 0. This process is meant to be launched with `open -n
// WhisperDictateRecorder.app --args <wav> <log> <pid>` and stopped with a
// signal, not with a hard kill - a hard kill leaves the WAV file without a
// proper header/footer.
//
// Requires an app bundle with NSMicrophoneUsageDescription in Info.plist:
// a bare CLI binary gets silent audio from macOS with no error and no
// permission dialog at all.

import AVFoundation
import Foundation

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}

final class Logger {
    let path: String
    init(path: String) {
        self.path = path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
    }

    func log(_ message: String) {
        let line = "\(timestamp()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }
}

guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write("Usage: VoiceRecorder <wav-path> <log-path> <pid-path>\n".data(using: .utf8)!)
    exit(2)
}

let wavPath = CommandLine.arguments[1]
let logPath = CommandLine.arguments[2]
let pidPath = CommandLine.arguments[3]

let logger = Logger(path: logPath)

func fail(_ message: String) -> Never {
    logger.log("ERROR: \(message)")
    try? FileManager.default.removeItem(atPath: pidPath)
    exit(1)
}

// Write our own PID immediately so the caller can find and signal us even
// before recording has actually started.
let pid = ProcessInfo.processInfo.processIdentifier
do {
    try "\(pid)".write(toFile: pidPath, atomically: true, encoding: .utf8)
} catch {
    fail("could not write pid file: \(error)")
}

// Request microphone permission if not yet determined, and wait for the
// user's decision before proceeding.
let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
if authStatus == .notDetermined {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .audio) { result in
        granted = result
        semaphore.signal()
    }
    semaphore.wait()
    if !granted {
        fail("microphone access denied")
    }
} else if authStatus != .authorized {
    fail("microphone access not authorized (status: \(authStatus.rawValue))")
}

let settings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVSampleRateKey: 16_000.0,
    AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsFloatKey: false,
]

let wavURL = URL(fileURLWithPath: wavPath)

let recorder: AVAudioRecorder
do {
    recorder = try AVAudioRecorder(url: wavURL, settings: settings)
} catch {
    fail("could not initialize recorder: \(error)")
}

guard recorder.record() else {
    fail("recorder.record() returned false")
}

logger.log("recording started")

func shutdown() {
    recorder.stop()
    let attributes = try? FileManager.default.attributesOfItem(atPath: wavPath)
    let size = (attributes?[.size] as? Int) ?? 0
    logger.log("stopped, wav: \(size) bytes")
    try? FileManager.default.removeItem(atPath: pidPath)
    exit(0)
}

// Signal handling: ignore the default disposition first, then use a
// DispatchSource so we can run our own cleanup instead of dying instantly.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { shutdown() }
sigintSource.resume()

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { shutdown() }
sigtermSource.resume()

RunLoop.main.run()
