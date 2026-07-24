import Combine
import Foundation
import ServiceManagement

enum LauncherBrowsingMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case verticalScroll
    case horizontalPaging

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verticalScroll: "向下滚动"
        case .horizontalPaging: "左右翻页"
        }
    }

    var description: String {
        switch self {
        case .verticalScroll:
            "使用连续的纵向列表浏览全部应用。"
        case .horizontalPaging:
            "每页显示固定数量的应用，通过横向滑动或翻页按钮切换。"
        }
    }

    var symbol: String {
        switch self {
        case .verticalScroll: "arrow.down"
        case .horizontalPaging: "rectangle.split.3x1"
        }
    }
}

enum PagingWheelBehavior: String, CaseIterable, Codable, Identifiable, Sendable {
    case shiftModified
    case direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shiftModified: "Shift + 滚轮"
        case .direct: "直接滚轮"
        }
    }

    var description: String {
        switch self {
        case .shiftModified:
            "按住 Shift 后滚动翻页：向上翻到上一页，向下翻到下一页；不按 Shift 时滚轮不会翻页。"
        case .direct:
            "无需按键：向上滚动翻到上一页，向下滚动翻到下一页。"
        }
    }
}

@MainActor
final class LauncherSettings: ObservableObject {
    /// User-configurable launcher panel size. The defaults reproduce the
    /// classic fixed layout (760 × 668 → 7 columns, 4 paged rows); ranges
    /// keep the panel usable on common screens and wide enough for the
    /// folder overlay card.
    static let defaultPanelWidth: Double = 760
    static let defaultPanelHeight: Double = 668
    static let panelWidthRange: ClosedRange<Double> = 640...1200
    static let panelHeightRange: ClosedRange<Double> = 560...900

    @Published var browsingMode: LauncherBrowsingMode {
        didSet {
            UserDefaults.standard.set(browsingMode.rawValue, forKey: Self.browsingModeKey)
        }
    }

    @Published var pagingWheelBehavior: PagingWheelBehavior {
        didSet {
            UserDefaults.standard.set(
                pagingWheelBehavior.rawValue,
                forKey: Self.pagingWheelBehaviorKey
            )
        }
    }

    @Published var panelWidth: Double {
        didSet {
            UserDefaults.standard.set(panelWidth, forKey: Self.panelWidthKey)
        }
    }

    @Published var panelHeight: Double {
        didSet {
            UserDefaults.standard.set(panelHeight, forKey: Self.panelHeightKey)
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin, launchAtLogin != oldValue else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    @Published private(set) var launchAtLoginError: String?

    private var isSyncingLaunchAtLogin = false

    private static let browsingModeKey = "AppTileDemo.LauncherBrowsingMode"
    private static let pagingWheelBehaviorKey = "AppTileDemo.PagingWheelBehavior"
    private static let panelWidthKey = "AppTileDemo.LauncherPanelWidth"
    private static let panelHeightKey = "AppTileDemo.LauncherPanelHeight"

    var panelSize: CGSize {
        CGSize(width: panelWidth, height: panelHeight)
    }

    var isUsingDefaultPanelSize: Bool {
        panelWidth == Self.defaultPanelWidth && panelHeight == Self.defaultPanelHeight
    }

    func resetPanelSize() {
        panelWidth = Self.defaultPanelWidth
        panelHeight = Self.defaultPanelHeight
    }

    init() {
        if let rawValue = UserDefaults.standard.string(forKey: Self.browsingModeKey),
           let savedMode = LauncherBrowsingMode(rawValue: rawValue) {
            browsingMode = savedMode
        } else {
            browsingMode = .verticalScroll
        }

        if let rawValue = UserDefaults.standard.string(forKey: Self.pagingWheelBehaviorKey),
           let savedBehavior = PagingWheelBehavior(rawValue: rawValue) {
            pagingWheelBehavior = savedBehavior
        } else {
            pagingWheelBehavior = .shiftModified
        }

        // double(forKey:) returns 0 when the key is absent; any stored value
        // is clamped so hand-edited defaults can never break the layout.
        let storedWidth = UserDefaults.standard.double(forKey: Self.panelWidthKey)
        panelWidth = storedWidth == 0
            ? Self.defaultPanelWidth
            : min(max(storedWidth, Self.panelWidthRange.lowerBound), Self.panelWidthRange.upperBound)

        let storedHeight = UserDefaults.standard.double(forKey: Self.panelHeightKey)
        panelHeight = storedHeight == 0
            ? Self.defaultPanelHeight
            : min(max(storedHeight, Self.panelHeightRange.lowerBound), Self.panelHeightRange.upperBound)

        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Re-reads the registration state from the system, in case the user
    /// changed it in System Settings > General > Login Items.
    func refreshLaunchAtLoginStatus() {
        let enabled = SMAppService.mainApp.status == .enabled
        if launchAtLogin != enabled {
            isSyncingLaunchAtLogin = true
            launchAtLogin = enabled
            isSyncingLaunchAtLogin = false
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            // Revert to the actual system state on failure.
            refreshLaunchAtLoginStatus()
        }
    }
}
