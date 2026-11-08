import Foundation
import MonetShotKit

/// "Vertical" where you start a recording: remembered, so every new take
/// opens in the editor already made for phones.
enum RecordLayout {
    static let key = "recordVertical"

    static var vertical: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The layout a new recording's edit starts with.
    static var layout: CanvasLayout { vertical ? .vertical : .landscape }
}
