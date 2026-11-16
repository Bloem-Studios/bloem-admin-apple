import SwiftUI

/// Bloem Admin's design tokens. The colors are named color sets in Assets.xcassets, each with a Light, a Dark
/// and an increased-contrast value (generated and measured by `scripts/theme-colors.py`); the rest is here.
///
/// The look in one paragraph: graphite neutrals (the web admin's), Bloem orange as the only accent, and a
/// quiet interface where color means something. Status is a word, with a dot only when it is an exception.
/// A small orange dot (`TallyDot`) means live right now, and nothing else is orange except selection and the
/// primary action.
enum Theme {
    // MARK: Surfaces

    /// The page behind everything.
    static let background = Color("BloemBackground")
    /// Cards, panels and list rows.
    static let surface = Color("BloemSurface")
    /// A control or a cell sitting on a surface.
    static let raised = Color("BloemRaised")
    /// The menu's own background, a step below the page.
    static let sidebar = Color("BloemSidebar")
    /// Behind the open page in the menu and the chosen tab: a raised fill, not a tint.
    static let selected = Color("BloemSelected")
    /// Outlines of controls: at least 3:1 against the page.
    static let outline = Color("BloemOutline")
    /// The one hairline: borders, dividers, chart grids.
    static let hairline = Color("BloemHairline")

    // MARK: Text

    /// Primary text.
    static let text = Color("BloemText")
    /// Secondary text, captions and quiet status; at least 4.5:1 on every surface.
    static let muted = Color("BloemTextMuted")

    // MARK: Accent

    /// Bloem orange. A darker orange on Light so that orange text, and white text on an orange fill, reach 4.5:1.
    static let accent = Color("AccentColor")
    /// The label on an accent fill.
    static let onAccent = Color("BloemOnAccent")
    /// The tally dot's orange (a little brighter than the accent on Light, as it is never text).
    static let tally = Color("BloemTally")
    /// Behind the selected menu row and the selected tab.
    static let selectionFill = selected

    // MARK: Status, as text (at least 4.5:1 on every surface)

    static let ok = Color("BloemOK")
    /// Amber: warnings, paused, a transcode. A different hue from the accent on purpose.
    static let warn = Color("BloemWarn")
    /// Failures only.
    static let danger = Color("BloemDanger")

    // MARK: Spacing and shape

    /// The 4 grid, the steps of docs/design.md: 4, 8, 12, 16, 24, 32. Compact rows and panels
    /// pad 16, cards 16 to 20, page edges 16 on a phone and 24 to 32 on a tablet.
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Nested radius is the outer radius minus the padding. Not everything is a pill.
    enum Radius {
        /// Marks inside a card: posters, thumbnails, legend swatches. A card's 12 minus its 8 of padding.
        static let inner: CGFloat = 4
        /// Buttons, fields, chips and navigation rows.
        static let control: CGFloat = 10
        /// Cards and panels.
        static let card: CGFloat = 12
        /// Large surfaces and sheets.
        static let large: CGFloat = 16
    }

    /// One easing curve for everything. Feedback takes 150 to 200 ms, an entrance 250; nothing loops except a
    /// live indicator, and nothing bounces.
    enum Motion {
        static let feedback = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
        static let enter = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.25)
    }

    /// The smallest a thing you tap may be (44 on iOS).
    static let minimumTarget: CGFloat = 44
}

/// `.foregroundStyle(.bloemMuted)` and friends, so call sites read like the system's own styles.
extension ShapeStyle where Self == Color {
    static var bloemText: Color { Theme.text }
    static var bloemMuted: Color { Theme.muted }
    static var bloemAccent: Color { Theme.accent }
    static var bloemOK: Color { Theme.ok }
    static var bloemWarn: Color { Theme.warn }
    static var bloemDanger: Color { Theme.danger }
    static var bloemHairline: Color { Theme.hairline }
}

extension View {
    /// A card: the surface colour, rounded, with a hairline border (both apps draw cards this way).
    func bloemCard(radius: CGFloat = Theme.Radius.card) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    /// The page: graphite behind a scrolling list or form instead of the system grouped background.
    func bloemPageBackground() -> some View {
        scrollContentBackground(.hidden).background(Theme.background.ignoresSafeArea())
    }
}
