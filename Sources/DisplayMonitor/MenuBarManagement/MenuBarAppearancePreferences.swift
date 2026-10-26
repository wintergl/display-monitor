import Foundation

enum MenuBarIconStyle: String, CaseIterable, Identifiable, Codable {
    case display
    case chevron
    case dots
    case grid
    case circle

    var id: Self { self }

    var title: String {
        switch self {
        case .display: return "显示器（默认）"
        case .chevron: return "双箭头"
        case .dots: return "省略号"
        case .grid: return "四宫格"
        case .circle: return "圆点"
        }
    }

    var symbolName: String {
        switch self {
        case .display: return "display"
        case .chevron: return "chevron.left.2"
        case .dots: return "ellipsis"
        case .grid: return "square.grid.2x2"
        case .circle: return "circle.fill"
        }
    }

    func symbolName(monitorSymbol: String) -> String {
        // Keep capture, pause and error feedback visible with every style.
        monitorSymbol == "display" ? symbolName : monitorSymbol
    }
}

enum MenuBarAutoHideDelay {
    static let defaultSeconds = 4
    static let range = 1...300

    static func clamped(_ seconds: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, seconds))
    }
}
