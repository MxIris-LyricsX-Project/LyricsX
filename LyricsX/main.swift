import AppKit

// Branch before NSApplicationMain: workers never create an AppDelegate, status item,
// preferences window, or player singleton. They share this signed bundle's identity.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--lyricsx-phone-worker",
   let role = PhoneWorkerRole(rawValue: CommandLine.arguments[2]) {
    PhoneWorkerRuntime.run(role: role)
} else {
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
