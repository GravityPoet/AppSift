import SwiftUI

/// User-overridable appearance setting that lives independently of the system
/// preference, mirroring the prototype's titlebar light/dark toggle.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @AppStorage("AppSift.Appearance") private var rawValue: String = AppearanceMode.system.rawValue

    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: rawValue) ?? .system }
        set { rawValue = newValue.rawValue; objectWillChange.send() }
    }
}

/// Centralized accent palette. One blue, one green for success, one orange
/// for warning, one red for destructive. Other tints exist for categorical
/// differentiation but the surface chrome only uses these four.
enum Tint {
    static let blue   = Color(red: 0.16, green: 0.49, blue: 1.00)
    static let green  = Color(red: 0.20, green: 0.82, blue: 0.57)
    static let orange = Color(red: 1.00, green: 0.58, blue: 0.04)
    static let purple = Color(red: 0.53, green: 0.36, blue: 1.00)
    static let pink   = Color(red: 1.00, green: 0.32, blue: 0.66)
    static let cyan   = Color(red: 0.20, green: 0.83, blue: 0.96)
    static let red    = Color(red: 1.00, green: 0.27, blue: 0.23)
    static let yellow = Color(red: 1.00, green: 0.78, blue: 0.04)
}

/// AppSift's visual identity. The palette keeps the blue of the eraser icon,
/// adds a cool violet for depth, and deliberately avoids the magenta-dominant
/// CleanMyMac look used as a layout reference.
enum AppBrand {
    // Keep the brand blue in interactive controls and status icons. Window
    // chrome stays neutral so dense tool surfaces remain easy to scan.
    static let midnight = Color(red: 0.075, green: 0.082, blue: 0.105)

    static func canvas(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? midnight
            : Color(red: 0.955, green: 0.957, blue: 0.970)
    }

    static func sidebar(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.095, green: 0.100, blue: 0.125)
            : Color(red: 0.925, green: 0.930, blue: 0.945)
    }

    static func card(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.145, green: 0.150, blue: 0.180)
            : Color.white.opacity(0.94)
    }

    static func cardBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.08)
    }
}

/// Shared window canvas. A neutral system-like surface keeps attention on the
/// current task instead of competing with every card and chart.
struct AppBackdrop: View {
    var sidebar = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        (sidebar
            ? AppBrand.sidebar(for: colorScheme)
            : AppBrand.canvas(for: colorScheme))
        .ignoresSafeArea()
    }
}

/// Shared animation vocabulary so every surface moves with the same feel.
/// Hover/selection feedback uses `snappy`, entrances and state swaps use
/// `gentle`, press acknowledgment uses `press`.
enum MotionTokens {
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.7)
    static let gentle = Animation.spring(response: 0.5, dampingFraction: 0.85)
    static let press  = Animation.easeOut(duration: 0.12)
}

/// Gradient pairs built from the flat `Tint` palette. Reserved for primary
/// CTAs and focal chrome — secondary surfaces stay flat.
enum TintGradient {
    static let accent = LinearGradient(
        colors: [Tint.blue, Tint.purple, Tint.cyan],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let destructive = LinearGradient(
        colors: [Tint.red, Tint.red.opacity(0.8)],
        startPoint: .top, endPoint: .bottom
    )
    static func of(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .top, endPoint: .bottom)
    }
}

/// Tinted square icon container used in the sidebar and on dashboard cards.
/// Single muted fill, thin border. When `glow` is set (selected sidebar row,
/// emphasized card) the tile uses a solid accent and a restrained halo.
struct IconTile: View {
    let systemName: String
    var tint: Color = Tint.blue
    var size: CGFloat = 26
    var corner: CGFloat = 7
    var glow: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(glow ? tint : tint.opacity(colorScheme == .dark ? 0.22 : 0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark
                                ? Color.white.opacity(glow ? 0.22 : 0.10)
                                : Color.white.opacity(glow ? 0.48 : 0.70),
                            lineWidth: 0.75
                        )
                }
                .shadow(
                    color: tint.opacity(glow ? 0.18 : 0),
                    radius: glow ? 7 : 0,
                    y: glow ? 3 : 0
                )
            Image(systemName: systemName)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(glow ? Color.white : tint)
        }
        .frame(width: size, height: size)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: glow)
    }
}

/// Card surface. Accent remains in the API for source compatibility, but card
/// chrome stays neutral so a page can contain many cards without visual noise.
/// Pass `material` only for a focal, transient panel.
struct CardSurface<Content: View>: View {
    var padding: CGFloat = 16
    /// Retained for callsite compatibility; the accent line is intentionally
    /// not rendered in the restrained design.
    var accent: Color? = nil
    var elevation: CardElevation = .standard
    var material: Material? = nil
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    if let material {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(material)
                    } else {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AppBrand.card(for: colorScheme))
                    }

                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        material != nil
                            ? Color.white.opacity(colorScheme == .dark ? 0.16 : 0.58)
                            : AppBrand.cardBorder(for: colorScheme),
                        lineWidth: 0.75
                    )
            )
            .shadow(
                color: .black.opacity(elevation.ambient),
                radius: elevation.ambientRadius,
                y: elevation.ambientY
            )
    }
}

enum CardElevation {
    case flat, standard, raised

    var ambient: Double {
        switch self {
        case .flat: return 0.0
        case .standard: return 0.06
        case .raised: return 0.11
        }
    }

    var ambientRadius: CGFloat {
        switch self {
        case .flat: return 0
        case .standard: return 8
        case .raised: return 16
        }
    }

    var ambientY: CGFloat {
        switch self {
        case .flat: return 0
        case .standard: return 3
        case .raised: return 7
        }
    }
}

/// Small status pill. Solid tint background at low opacity, no gradient.
struct StatusChip: View {
    let label: String
    var systemImage: String? = nil
    var tint: Color = Tint.blue
    var foreground: Color? = nil
    var textAccessibilityIdentifier: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
            }
            if let textAccessibilityIdentifier {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .accessibilityIdentifier(textAccessibilityIdentifier)
            } else {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .foregroundStyle(foreground ?? tint)
    }
}

/// Hover feedback for informational cards. Plain mode is a subtle scale;
/// `lift` mode adds a small rise and soft shadow. This modifier deliberately
/// owns no click or drag gesture so cards inside a ScrollView never compete
/// with scrolling. Interactive controls should use ButtonStyle for native
/// press, keyboard, and accessibility behavior.
struct HoverLift: ViewModifier {
    @State private var hovering = false
    var hoverScale: CGFloat = 1.006
    var lift: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1.0 : (hovering ? (lift ? 1.02 : hoverScale) : 1.0))
            .offset(y: lift && hovering && !reduceMotion ? -2 : 0)
            .shadow(color: .black.opacity(lift && hovering ? 0.12 : 0),
                    radius: lift && hovering ? 14 : 0,
                    y: lift && hovering ? 6 : 0)
            .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverLift(hoverScale: CGFloat = 1.006, lift: Bool = false) -> some View {
        modifier(HoverLift(hoverScale: hoverScale, lift: lift))
    }
}

/// Solid rounded CTA with a restrained tinted shadow — the primary-action style.
/// Hover lifts the glow and scale; press squeezes. `breathes` adds a gentle
/// idle glow pulse (radius only, no scale) for the single hero CTA on an
/// otherwise calm screen. All motion is suppressed under Reduce Motion.
struct GlowProminentButtonStyle: ButtonStyle {
    var tint: Color = Tint.blue
    /// Retained for existing callsites; the CTA now uses one semantic tint.
    var gradient: LinearGradient = TintGradient.accent
    var breathes: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        GlowBody(configuration: configuration, tint: tint, breathes: breathes)
    }

    private struct GlowBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let breathes: Bool

        @State private var hovering = false
        @State private var breathe = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                )
                .saturation(isEnabled ? 1 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .shadow(
                    color: isEnabled
                        ? tint.opacity(hovering ? 0.24 : (breathe ? 0.18 : 0.12))
                        : .clear,
                    radius: hovering ? 10 : (breathe ? 8 : 5),
                    y: 3
                )
                .scaleEffect(
                    reduceMotion || !isEnabled
                        ? 1
                        : (configuration.isPressed ? 0.97 : (hovering ? 1.015 : 1))
                )
                .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
                .animation(reduceMotion ? nil : MotionTokens.press, value: configuration.isPressed)
                .onHover { hovering = isEnabled && $0 }
                .onAppear {
                    guard breathes, !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        breathe = true
                    }
                }
        }
    }
}

/// Checkbox replacement with a springy check pop. Visually matches the size
/// of the native control so adopting it doesn't shift row layout. Keeps the
/// native checkbox's accessibility semantics (role, checked value, Space-key
/// toggling, VoiceOver) via accessibilityRepresentation so swapping it in
/// doesn't regress keyboard/screen-reader users.
struct AnimatedCheckboxStyle: ToggleStyle {
    var tint: Color = Tint.blue

    func makeBody(configuration: Configuration) -> some View {
        CheckBody(configuration: configuration, tint: tint)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
                    .toggleStyle(.checkbox)
            }
    }

    private struct CheckBody: View {
        let configuration: ToggleStyleConfiguration
        let tint: Color
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(configuration.isOn ? tint : Color.primary.opacity(0.05))
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .strokeBorder(configuration.isOn ? tint : Color.primary.opacity(0.25), lineWidth: 1)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .scaleEffect(configuration.isOn ? 1 : 0.3)
                        .opacity(configuration.isOn ? 1 : 0)
                }
                .frame(width: 15, height: 15)
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.6), value: configuration.isOn)

                configuration.label
            }
            .contentShape(Rectangle())
            .onTapGesture { configuration.isOn.toggle() }
        }
    }
}
