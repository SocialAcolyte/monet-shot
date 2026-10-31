import Foundation
import MonetShotKit

// Entry point. One-shot command-line modes (e.g. `MonetShot --status`) are
// answered here, before AppKit starts; anything else launches the menu bar app.
if let output = CommandLineMode.run(Array(CommandLine.arguments.dropFirst())) {
    print(output.text)
    exit(output.status)
}
MonetShotApp.main()
