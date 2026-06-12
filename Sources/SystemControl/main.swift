import AppKit

if CommandLine.arguments.contains("--probe") {
    runProbe()
    exit(0)
}

if let idx = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let path = CommandLine.arguments.count > idx + 1
        ? CommandLine.arguments[idx + 1]
        : "/tmp/systemcontrol_snapshot.png"
    MainActor.assumeIsolated { runSnapshot(to: path) }
    exit(0)
}

SystemControlApp.main()
