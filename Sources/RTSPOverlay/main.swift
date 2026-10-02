import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--probe" {
    Probe.run(Array(arguments.dropFirst()))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // solo icona nella barra dei menu, niente Dock
app.run()
