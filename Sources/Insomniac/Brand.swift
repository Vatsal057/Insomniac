import SwiftUI

/// Insomniac brand palette — derived from the Watchful Eye app icon.
///
/// Warm amber tones rooted in the iris of the eye icon. Use these instead of
/// `.accentColor`, `.indigo`, or raw `.orange` throughout the app.
enum Brand {
    // MARK: - SwiftUI Colors

    /// Primary brand accent — warm amber. Use for section icons, tints, active controls.
    static let color = Color(red: 0.90, green: 0.68, blue: 0.22)

    /// Subtle brand fill — amber at 15% opacity. Use for hero circle backgrounds,
    /// icon badge fills, and tinted surface areas.
    static let subtle = color.opacity(0.15)

    /// Active/ON state — slightly brighter golden. Use for timer text, active status.
    static let active = Color(red: 0.95, green: 0.75, blue: 0.30)

    /// Dormant/OFF state — standard secondary. Use for disabled status text.
    static let dormant = Color.secondary

    // MARK: - AppKit Colors (for NSMenu / NSStatusBar)

    /// NSColor matching `active` — for menu bar attributed strings.
    static let activeNS = NSColor(red: 0.95, green: 0.75, blue: 0.30, alpha: 1.0)

    /// NSColor matching `color` — for menu item attributed strings.
    static let colorNS = NSColor(red: 0.90, green: 0.68, blue: 0.22, alpha: 1.0)
}

/// A compact SwiftUI rendition of the Watchful Eye app icon.
/// Use in About, Onboarding, and anywhere the brand hero is needed.
struct BrandEyeIcon: View {
    var size: CGFloat = 80

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.11, blue: 0.18),
                            Color(red: 0.05, green: 0.05, blue: 0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Ambient glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Brand.active.opacity(0.25),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.35
                    )
                )
                .frame(width: size * 0.7, height: size * 0.7)

            // Eye shape — simplified almond using SF Symbol
            Image(systemName: "eye")
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.85, blue: 0.55),
                            Brand.color
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
