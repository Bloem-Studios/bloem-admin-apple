import CoreText
import SwiftUI
import UIKit

/// Plus Jakarta Sans (SIL OFL 1.1, LICENSES/PlusJakartaSans-OFL.txt), the one typeface of the six Bloem staff
/// apps, as one variable font (weight axis 200 to 800) registered through `UIAppFonts`. The app and the widget
/// extension both compile this file, so a widget is set in the same type as the app.
///
/// The scale is the shared one in `docs/design.md`, the same fifteen named styles as the
/// Android app. A view picks a style by name (`.bloemText(.bodyMedium)`), never by a number or a system
/// style. Three weights only: 400 for reading, 500 for labels and row titles, 600 for headings. Figures are
/// always tabular. Dynamic Type still scales every style (and its line height).
enum BloemWeight: Int, Sendable {
    case regular = 400
    case medium = 500
    case semibold = 600
}

enum BloemTextStyle: CaseIterable, Sendable {
    case displayLarge, displayMedium, displaySmall
    case headlineLarge, headlineMedium, headlineSmall
    case titleLarge, titleMedium, titleSmall
    case bodyLarge, bodyMedium, bodySmall
    case labelLarge, labelMedium, labelSmall

    /// Point size at the default Dynamic Type setting.
    var size: CGFloat {
        switch self {
        case .displayLarge: 45
        case .displayMedium: 36
        case .displaySmall: 32
        case .headlineLarge: 28
        case .headlineMedium: 24
        case .headlineSmall: 22
        case .titleLarge: 20
        case .titleMedium: 16
        case .titleSmall: 14
        case .bodyLarge: 16
        case .bodyMedium: 14
        case .bodySmall: 12
        case .labelLarge: 14
        case .labelMedium: 12
        case .labelSmall: 11
        }
    }

    /// Line height at the default Dynamic Type setting.
    var lineHeight: CGFloat {
        switch self {
        case .displayLarge: 52
        case .displayMedium: 44
        case .displaySmall: 40
        case .headlineLarge: 36
        case .headlineMedium: 32
        case .headlineSmall: 28
        case .titleLarge: 28
        case .titleMedium: 24
        case .titleSmall: 20
        case .bodyLarge: 24
        case .bodyMedium: 20
        case .bodySmall: 16
        case .labelLarge: 20
        case .labelMedium: 16
        case .labelSmall: 16
        }
    }

    var weight: BloemWeight {
        switch self {
        case .displayLarge, .displayMedium, .displaySmall,
             .headlineLarge, .headlineMedium, .headlineSmall, .titleLarge: .semibold
        case .titleMedium, .titleSmall, .labelLarge, .labelMedium, .labelSmall: .medium
        case .bodyLarge, .bodyMedium, .bodySmall: .regular
        }
    }

    /// The system style whose Dynamic Type curve this style scales along.
    var scalesLike: UIFont.TextStyle {
        switch self {
        case .displayLarge, .displayMedium, .displaySmall: .largeTitle
        case .headlineLarge: .title1
        case .headlineMedium, .headlineSmall: .title2
        case .titleLarge: .title3
        case .titleMedium: .headline
        case .titleSmall, .bodyMedium, .labelLarge: .subheadline
        case .bodyLarge: .body
        case .bodySmall: .footnote
        case .labelMedium: .caption1
        case .labelSmall: .caption2
        }
    }
}

enum BloemFont {
    /// The font's PostScript name (the variable font's default instance, 400).
    static let familyName = "PlusJakartaSans-Regular"

    /// The weight axis's four-character tag, 'wght'.
    private static let weightAxis = 0x7767_6874

    private static let tabularFigures: [UIFontDescriptor.FeatureKey: Int] = [
        .type: kNumberSpacingType,
        .selector: kMonospacedNumbersSelector,
    ]

    /// The font at a size and weight, with tabular figures on. Not scaled for Dynamic Type.
    static func unscaled(size: CGFloat, weight: BloemWeight) -> UIFont {
        let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let descriptor = UIFontDescriptor(fontAttributes: [
            .name: familyName,
            variation: [weightAxis: weight.rawValue],
            // Tabular figures: Apple's name for the font's 'tnum' feature, the one `monospacedDigit()` asks for.
            .featureSettings: [tabularFigures],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// A style's font, scaled for a Dynamic Type setting.
    static func uiFont(_ style: BloemTextStyle, category: UIContentSizeCategory = .large) -> UIFont {
        let base = unscaled(size: style.size, weight: style.weight)
        return UIFontMetrics(forTextStyle: style.scalesLike)
            .scaledFont(for: base, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }

    /// The extra space between lines that turns the font's own line height into the style's, at the same scale.
    static func lineSpacing(_ style: BloemTextStyle, font: UIFont) -> CGFloat {
        let scaledLineHeight = style.lineHeight * font.pointSize / style.size
        return max(0, scaledLineHeight - font.lineHeight)
    }
}

extension Font {
    /// A named style at the default Dynamic Type size. Prefer `.bloemText(_:)`, which follows the setting.
    static func bloem(_ style: BloemTextStyle) -> Font {
        Font(BloemFont.uiFont(style) as CTFont)
    }
}

private struct BloemTextModifier: ViewModifier {
    let style: BloemTextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        let font = BloemFont.uiFont(style, category: dynamicTypeSize.contentSizeCategory)
        content
            .font(Font(font as CTFont))
            .lineSpacing(BloemFont.lineSpacing(style, font: font))
    }
}

private struct BloemFontModifier: ViewModifier {
    let style: BloemTextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(Font(BloemFont.uiFont(style, category: dynamicTypeSize.contentSizeCategory) as CTFont))
    }
}

extension View {
    /// Sets the text in one of the fifteen named styles: Plus Jakarta Sans, its weight, size and line height,
    /// tabular figures, scaled with Dynamic Type.
    func bloemText(_ style: BloemTextStyle) -> some View {
        modifier(BloemTextModifier(style: style))
    }

    /// Only the font of a style, for the root view: controls the app does not style itself (fields, pickers,
    /// button labels) inherit it. It leaves the line spacing alone, as that would reach every child.
    func bloemFont(_ style: BloemTextStyle) -> some View {
        modifier(BloemFontModifier(style: style))
    }
}

extension DynamicTypeSize {
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}
