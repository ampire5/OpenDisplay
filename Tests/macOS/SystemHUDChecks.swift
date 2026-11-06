import AppKit
import DisplayDomain
import TopologyCore
@main struct Checks {
 @MainActor static func main() {
  _ = NSApplication.shared
  let hud = OSDHUDController()
  precondition(hud.nativeAvailable, "System OSD service must be available")
  hud.present(OSDContent(kind: .brightness, value: 0.5), cgDisplayID: CGMainDisplayID(),
              style: .native, position: .bottomCenter)
  precondition(!NSApp.windows.contains { $0 is NSPanel && $0.isVisible },
               "Native mode must not create a visible custom HUD panel")
  RunLoop.current.run(until: Date().addingTimeInterval(2))
  print("PASS: Native HUD has no custom panel")
 }
}
