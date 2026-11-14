import SwiftUI
import UIKit

enum TellerTheme {
    static let paper = color(light: 0xf7f1e7, dark: 0x201b19)
    static let card = color(light: 0xfffbf4, dark: 0x2a2320)
    static let ink = color(light: 0x30211e, dark: 0xf7e9dc)
    static let muted = color(light: 0x695752, dark: 0xd0b8ac)
    static let border = color(light: 0xdcccbd, dark: 0x53413c)
    static let accent = color(light: 0x863f35, dark: 0xf1ac94)
    static let softAccent = color(light: 0xf3dfd5, dark: 0x472c29)
    static let onAccent = color(light: 0xfffcf5, dark: 0x301b18)

    private static func color(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: Double((value >> 16) & 255) / 255,
                green: Double((value >> 8) & 255) / 255,
                blue: Double(value & 255) / 255,
                alpha: 1
            )
        })
    }
}

struct TellerPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(isEnabled ? TellerTheme.onAccent : TellerTheme.muted)
            .background(isEnabled ? TellerTheme.accent : TellerTheme.paper, in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct TellerCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(TellerTheme.card, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(TellerTheme.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func tellerCard() -> some View {
        modifier(TellerCardModifier())
    }
}
