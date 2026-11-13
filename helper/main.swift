// GyroSteer: steer BeamNG.drive by tilting a controller like a wheel. See README.md.
//   GyroSteer.app             the window
//   GyroSteer --selftest      checks the tilt maths on made-up sensor data, then exits

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Engine.shared.start()
        let args = CommandLine.arguments
        if args.contains("--simulate") { Engine.shared.setSimulate(true) }
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        // For checking the layout: --snapshot <file.png> saves the window after a few seconds, then quits.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                let e = Engine.shared
                print("window refreshes/s: \(e.refreshRate), motion updates/s: \(e.motionRate)")
                if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Engine.shared.shutdown()
    }
}

struct GyroSteerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("GyroSteer", id: "main") {
            ContentView(engine: Engine.shared)
        }
        .defaultSize(width: 1120, height: 780)
    }
}

if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTest() ? 0 : 1)
}
GyroSteerApp.main()
