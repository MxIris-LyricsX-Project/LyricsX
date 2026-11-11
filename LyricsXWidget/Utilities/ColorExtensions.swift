import SwiftUI
import LyricsXWidgetShared

extension CodableColor {
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var gradientColors: [Color] {
        let baseColor = swiftUIColor
        let darkerColor = Color(red: red * 0.5, green: green * 0.5, blue: blue * 0.5, opacity: alpha)
        return [baseColor, darkerColor]
    }
}

extension Color {
    static let widgetDefaultBackground = Color(red: 0.1, green: 0.1, blue: 0.12)
    static let widgetDefaultBackgroundDarker = Color(red: 0.05, green: 0.05, blue: 0.07)

    static var defaultGradientColors: [Color] {
        [.widgetDefaultBackground, .widgetDefaultBackgroundDarker]
    }
}
