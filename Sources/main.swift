import AppKit
import Foundation

// Entry point. Two modes:
//
//   TrackLivery                                  -> opens the drop window (normal use)
//   TrackLivery --cli <file.wav> [--no-import]   -> runs the whole pipeline in the
//                                                   terminal (used for testing)
//
// The pipeline itself lives in Pipeline.swift; each step is a small file so new
// features are easy to add (see README.md).

let arguments = CommandLine.arguments

if let cliIndex = arguments.firstIndex(of: "--cli") {
    let rest = arguments[(cliIndex + 1)...]
    guard let file = rest.first else {
        FileHandle.standardError.write("usage: TrackLivery --cli <file.wav> [--no-import]\n".data(using: .utf8)!)
        exit(64)
    }
    let importToMusic = !arguments.contains("--no-import")
    let semaphore = DispatchSemaphore(value: 0)
    let runner = PipelineRunner()
    runner.onMainQueue = false // no run loop in CLI mode
    runner.importToMusic = importToMusic
    // The delegate is weak; keep a strong reference for the lifetime of the run.
    let consoleDelegate = ConsolePipelineDelegate(semaphore: semaphore)
    runner.delegate = consoleDelegate
    runner.run(fileURL: URL(fileURLWithPath: file))
    semaphore.wait()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
