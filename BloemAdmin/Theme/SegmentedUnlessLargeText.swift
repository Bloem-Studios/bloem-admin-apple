import SwiftUI

// MARK: Segmented controls and large text

/// A segmented control while the text is an ordinary size; a menu at the accessibility sizes. The system's segments keep
/// their small label size whatever the person chose in Settings, and three of them would not fit a line at that size, so
/// the same choice is one menu button that scales with the text.
private struct SegmentedUnlessLargeText: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.pickerStyle(.menu)
        } else {
            content.pickerStyle(.segmented)
        }
    }
}

extension View {
    /// `pickerStyle(.segmented)` that does not shrink the choice to unreadable segments at the accessibility text sizes.
    func segmentedUnlessLargeText() -> some View { modifier(SegmentedUnlessLargeText()) }
}
