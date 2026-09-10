import SwiftUI

/// Use full-width stat tiles at accessibility sizes so labels and values can expand without clipping.
public enum SparkStatTileLayout {
    /// Grid columns for a strip of stat tiles.
    public static func columns(
        minimum: CGFloat = 150,
        spacing: CGFloat = 12,
        usesAccessibilityTextSize: Bool
    ) -> [GridItem] {
        if usesAccessibilityTextSize {
            return [GridItem(.flexible(), spacing: spacing)]
        }
        return [GridItem(.adaptive(minimum: minimum), spacing: spacing)]
    }

    /// Use a minimum tile height that can expand for accessibility text.
    public static func minimumHeight(usesAccessibilityTextSize: Bool) -> CGFloat? {
        usesAccessibilityTextSize ? nil : 96
    }

    /// Limit narrow-tile supporting text while allowing full-width content to wrap completely.
    public static func detailLineLimit(usesAccessibilityTextSize: Bool) -> Int? {
        usesAccessibilityTextSize ? nil : 2
    }

    /// Wrap headline values at accessibility sizes instead of shrinking requested text.
    public static func scalesValueToFit(usesAccessibilityTextSize: Bool) -> Bool {
        !usesAccessibilityTextSize
    }
}
