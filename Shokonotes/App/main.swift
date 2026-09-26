import AppKit

// NSApplication.delegate is weak. Retain the instance here or launch
// callbacks never run.
private let appDelegate = AppDelegate()

NSApplication.shared.delegate = appDelegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
