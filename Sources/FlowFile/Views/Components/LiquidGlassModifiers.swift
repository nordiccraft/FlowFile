import SwiftUI

struct GlassPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    var tint: Color? = nil
    var interactive: Bool = false

    func body(content: Content) -> some View {
        let baseGlass: Glass = {
            var g = Glass.regular
            if let tint {
                g = g.tint(tint)
            }
            if interactive {
                g = g.interactive()
            }
            return g
        }()

        content
            .glassEffect(baseGlass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func liquidGlassPanel(
        cornerRadius: CGFloat = 14,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }
}
