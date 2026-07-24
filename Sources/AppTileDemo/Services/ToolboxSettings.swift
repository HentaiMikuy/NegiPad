import Combine
import Foundation

/// Feature switches for the launcher's built-in mini tools (the calculator
/// today; color picker and friends later), persisted per user.
@MainActor
final class ToolboxSettings: ObservableObject {
    @Published var isCalculatorEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                isCalculatorEnabled,
                forKey: Self.calculatorEnabledKey
            )
        }
    }

    private static let calculatorEnabledKey = "AppTileDemo.Toolbox.CalculatorEnabled"

    init() {
        // Enabled out of the box so the tool is discoverable; the stored
        // value only takes over once the user has touched the toggle.
        if UserDefaults.standard.object(forKey: Self.calculatorEnabledKey) == nil {
            isCalculatorEnabled = true
        } else {
            isCalculatorEnabled = UserDefaults.standard.bool(
                forKey: Self.calculatorEnabledKey
            )
        }
    }
}
