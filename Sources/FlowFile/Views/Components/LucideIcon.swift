import SwiftUI

enum LucideIconKind {
    case shieldCheck
    case mousePointerClick
    case checkCircle
    case check
    case xCircle
    case x
    case copy
    case cloud
    case cloudDownload
    case columns2
    case compareArrows
    case inbox
    case share
    case sparkles
    case globe
    case settings
    case refreshCw
    case arrowRight
    case arrowLeft
    case gitBranch
    case archive
}

/// Crisp, monoline geometric icons rendered on a 24x24 grid in the Lucide style
/// (uniform stroke, round caps, round joins, zero cartoon fills or generic emojis).
struct LucideIcon: View {
    let kind: LucideIconKind
    var size: CGFloat = 16
    var lineWidth: CGFloat = 1.85

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 24.0
            var ctx = context
            ctx.scaleBy(x: scale, y: scale)

            let style = StrokeStyle(
                lineWidth: lineWidth,
                lineCap: .round,
                lineJoin: .round
            )
            let path = buildPath(for: kind)
            ctx.stroke(path, with: .foreground, style: style)
        }
        .frame(width: size, height: size)
    }

    private func buildPath(for kind: LucideIconKind) -> Path {
        var p = Path()

        switch kind {
        case .shieldCheck:
            p.move(to: CGPoint(x: 12, y: 2.5))
            p.addLine(to: CGPoint(x: 19.5, y: 5.5))
            p.addLine(to: CGPoint(x: 19.5, y: 12.2))
            p.addQuadCurve(to: CGPoint(x: 12, y: 21.5), control: CGPoint(x: 19.5, y: 18.2))
            p.addQuadCurve(to: CGPoint(x: 4.5, y: 12.2), control: CGPoint(x: 4.5, y: 18.2))
            p.addLine(to: CGPoint(x: 4.5, y: 5.5))
            p.closeSubpath()

            p.move(to: CGPoint(x: 9, y: 12.2))
            p.addLine(to: CGPoint(x: 11.2, y: 14.4))
            p.addLine(to: CGPoint(x: 15.3, y: 10.2))

        case .mousePointerClick:
            // Click rays
            p.move(to: CGPoint(x: 7.2, y: 2.5))
            p.addLine(to: CGPoint(x: 8.1, y: 5.3))
            p.move(to: CGPoint(x: 5.3, y: 8.1))
            p.addLine(to: CGPoint(x: 2.5, y: 7.2))
            p.move(to: CGPoint(x: 13.8, y: 4.3))
            p.addLine(to: CGPoint(x: 11.8, y: 6.3))
            p.move(to: CGPoint(x: 6.3, y: 11.8))
            p.addLine(to: CGPoint(x: 4.3, y: 13.8))
            // Geometric pointer
            p.move(to: CGPoint(x: 9.2, y: 9.2))
            p.addLine(to: CGPoint(x: 13.8, y: 20.8))
            p.addLine(to: CGPoint(x: 15.7, y: 15.7))
            p.addLine(to: CGPoint(x: 20.8, y: 13.8))
            p.closeSubpath()

        case .checkCircle:
            p.addEllipse(in: CGRect(x: 2.5, y: 2.5, width: 19, height: 19))
            p.move(to: CGPoint(x: 8.8, y: 12.3))
            p.addLine(to: CGPoint(x: 11.1, y: 14.6))
            p.addLine(to: CGPoint(x: 15.5, y: 10.0))

        case .check:
            p.move(to: CGPoint(x: 4.5, y: 12.5))
            p.addLine(to: CGPoint(x: 9.5, y: 17.5))
            p.addLine(to: CGPoint(x: 19.5, y: 6.5))

        case .xCircle:
            p.addEllipse(in: CGRect(x: 2.5, y: 2.5, width: 19, height: 19))
            p.move(to: CGPoint(x: 14.8, y: 9.2))
            p.addLine(to: CGPoint(x: 9.2, y: 14.8))
            p.move(to: CGPoint(x: 9.2, y: 9.2))
            p.addLine(to: CGPoint(x: 14.8, y: 14.8))

        case .x:
            p.move(to: CGPoint(x: 18, y: 6))
            p.addLine(to: CGPoint(x: 6, y: 18))
            p.move(to: CGPoint(x: 6, y: 6))
            p.addLine(to: CGPoint(x: 18, y: 18))

        case .copy:
            p.addRoundedRect(in: CGRect(x: 8.5, y: 8.5, width: 12.5, height: 12.5), cornerSize: CGSize(width: 2.2, height: 2.2))
            p.move(to: CGPoint(x: 5, y: 15.5))
            p.addLine(to: CGPoint(x: 4, y: 15.5))
            p.addQuadCurve(to: CGPoint(x: 3, y: 14.5), control: CGPoint(x: 3, y: 15.5))
            p.addLine(to: CGPoint(x: 3, y: 4.5))
            p.addQuadCurve(to: CGPoint(x: 4.5, y: 3), control: CGPoint(x: 3, y: 3))
            p.addLine(to: CGPoint(x: 14.5, y: 3))
            p.addQuadCurve(to: CGPoint(x: 15.5, y: 4), control: CGPoint(x: 15.5, y: 3))
            p.addLine(to: CGPoint(x: 15.5, y: 5))

        case .cloud:
            p.move(to: CGPoint(x: 17.5, y: 19))
            p.addLine(to: CGPoint(x: 7, y: 19))
            p.addQuadCurve(to: CGPoint(x: 2.5, y: 14.5), control: CGPoint(x: 2.5, y: 19))
            p.addQuadCurve(to: CGPoint(x: 6.8, y: 10.2), control: CGPoint(x: 2.5, y: 10.5))
            p.addQuadCurve(to: CGPoint(x: 12.5, y: 5), control: CGPoint(x: 7.8, y: 5))
            p.addQuadCurve(to: CGPoint(x: 18, y: 10.8), control: CGPoint(x: 17.2, y: 5))
            p.addQuadCurve(to: CGPoint(x: 21.5, y: 14.8), control: CGPoint(x: 21.5, y: 11))
            p.addQuadCurve(to: CGPoint(x: 17.5, y: 19), control: CGPoint(x: 21.5, y: 19))

        case .cloudDownload:
            p.move(to: CGPoint(x: 7, y: 18.5))
            p.addQuadCurve(to: CGPoint(x: 2.5, y: 14.2), control: CGPoint(x: 2.5, y: 18.2))
            p.addQuadCurve(to: CGPoint(x: 6.8, y: 9.8), control: CGPoint(x: 2.5, y: 10.2))
            p.addQuadCurve(to: CGPoint(x: 12.5, y: 4.8), control: CGPoint(x: 7.8, y: 4.8))
            p.addQuadCurve(to: CGPoint(x: 18, y: 10.4), control: CGPoint(x: 17.2, y: 4.8))
            p.addQuadCurve(to: CGPoint(x: 21.5, y: 14.4), control: CGPoint(x: 21.5, y: 10.6))
            p.addQuadCurve(to: CGPoint(x: 17.5, y: 18.5), control: CGPoint(x: 21.5, y: 18.2))
            // Arrow down
            p.move(to: CGPoint(x: 12, y: 11.5))
            p.addLine(to: CGPoint(x: 12, y: 20.5))
            p.move(to: CGPoint(x: 8.8, y: 17.3))
            p.addLine(to: CGPoint(x: 12, y: 20.5))
            p.addLine(to: CGPoint(x: 15.2, y: 17.3))

        case .columns2:
            p.addRoundedRect(in: CGRect(x: 3, y: 3.5, width: 18, height: 17), cornerSize: CGSize(width: 2.2, height: 2.2))
            p.move(to: CGPoint(x: 12, y: 3.5))
            p.addLine(to: CGPoint(x: 12, y: 20.5))

        case .compareArrows:
            // Top arrow right
            p.move(to: CGPoint(x: 4, y: 8))
            p.addLine(to: CGPoint(x: 20, y: 8))
            p.move(to: CGPoint(x: 16, y: 4.5))
            p.addLine(to: CGPoint(x: 20, y: 8))
            p.addLine(to: CGPoint(x: 16, y: 11.5))
            // Bottom arrow left
            p.move(to: CGPoint(x: 20, y: 16))
            p.addLine(to: CGPoint(x: 4, y: 16))
            p.move(to: CGPoint(x: 8, y: 12.5))
            p.addLine(to: CGPoint(x: 4, y: 16))
            p.addLine(to: CGPoint(x: 8, y: 19.5))

        case .inbox:
            p.move(to: CGPoint(x: 4.8, y: 4))
            p.addLine(to: CGPoint(x: 19.2, y: 4))
            p.addLine(to: CGPoint(x: 21.5, y: 13))
            p.addLine(to: CGPoint(x: 21.5, y: 19))
            p.addQuadCurve(to: CGPoint(x: 19.5, y: 20.5), control: CGPoint(x: 21.5, y: 20.5))
            p.addLine(to: CGPoint(x: 4.5, y: 20.5))
            p.addQuadCurve(to: CGPoint(x: 2.5, y: 19), control: CGPoint(x: 2.5, y: 20.5))
            p.addLine(to: CGPoint(x: 2.5, y: 13))
            p.closeSubpath()

            p.move(to: CGPoint(x: 2.5, y: 13))
            p.addLine(to: CGPoint(x: 8.2, y: 13))
            p.addLine(to: CGPoint(x: 9.8, y: 15.8))
            p.addLine(to: CGPoint(x: 14.2, y: 15.8))
            p.addLine(to: CGPoint(x: 15.8, y: 13))
            p.addLine(to: CGPoint(x: 21.5, y: 13))

        case .share:
            p.move(to: CGPoint(x: 12, y: 3.5))
            p.addLine(to: CGPoint(x: 12, y: 15.5))
            p.move(to: CGPoint(x: 8, y: 7.5))
            p.addLine(to: CGPoint(x: 12, y: 3.5))
            p.addLine(to: CGPoint(x: 16, y: 7.5))

            p.move(to: CGPoint(x: 4.5, y: 13.5))
            p.addLine(to: CGPoint(x: 4.5, y: 19))
            p.addQuadCurve(to: CGPoint(x: 6.5, y: 20.5), control: CGPoint(x: 4.5, y: 20.5))
            p.addLine(to: CGPoint(x: 17.5, y: 20.5))
            p.addQuadCurve(to: CGPoint(x: 19.5, y: 19), control: CGPoint(x: 19.5, y: 20.5))
            p.addLine(to: CGPoint(x: 19.5, y: 13.5))

        case .sparkles:
            // Lucide 4-point star
            p.move(to: CGPoint(x: 11, y: 3))
            p.addQuadCurve(to: CGPoint(x: 19, y: 11), control: CGPoint(x: 11, y: 11))
            p.addQuadCurve(to: CGPoint(x: 11, y: 19), control: CGPoint(x: 11, y: 11))
            p.addQuadCurve(to: CGPoint(x: 3, y: 11), control: CGPoint(x: 11, y: 11))
            p.addQuadCurve(to: CGPoint(x: 11, y: 3), control: CGPoint(x: 11, y: 11))
            // Accent cross
            p.move(to: CGPoint(x: 19, y: 3.5))
            p.addLine(to: CGPoint(x: 19, y: 7.5))
            p.move(to: CGPoint(x: 17, y: 5.5))
            p.addLine(to: CGPoint(x: 21, y: 5.5))

        case .globe:
            p.addEllipse(in: CGRect(x: 2.5, y: 2.5, width: 19, height: 19))
            p.move(to: CGPoint(x: 2.5, y: 12))
            p.addLine(to: CGPoint(x: 21.5, y: 12))
            p.addEllipse(in: CGRect(x: 7.8, y: 2.5, width: 8.4, height: 19))

        case .settings:
            p.addEllipse(in: CGRect(x: 8.5, y: 8.5, width: 7, height: 7))
            p.addEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))

        case .refreshCw:
            p.move(to: CGPoint(x: 20, y: 11))
            p.addQuadCurve(to: CGPoint(x: 12, y: 4), control: CGPoint(x: 19, y: 4))
            p.addQuadCurve(to: CGPoint(x: 4, y: 12), control: CGPoint(x: 4.5, y: 4.5))
            p.addQuadCurve(to: CGPoint(x: 12, y: 20), control: CGPoint(x: 4.5, y: 19.5))
            p.addQuadCurve(to: CGPoint(x: 19.5, y: 15), control: CGPoint(x: 17.5, y: 20))
            p.move(to: CGPoint(x: 20, y: 5.5))
            p.addLine(to: CGPoint(x: 20, y: 11))
            p.addLine(to: CGPoint(x: 14.5, y: 11))

        case .arrowRight:
            p.move(to: CGPoint(x: 5, y: 12))
            p.addLine(to: CGPoint(x: 19, y: 12))
            p.move(to: CGPoint(x: 13, y: 6))
            p.addLine(to: CGPoint(x: 19, y: 12))
            p.addLine(to: CGPoint(x: 13, y: 18))

        case .arrowLeft:
            p.move(to: CGPoint(x: 19, y: 12))
            p.addLine(to: CGPoint(x: 5, y: 12))
            p.move(to: CGPoint(x: 11, y: 6))
            p.addLine(to: CGPoint(x: 5, y: 12))
            p.addLine(to: CGPoint(x: 11, y: 18))

        case .gitBranch:
            p.addEllipse(in: CGRect(x: 4.5, y: 3.5, width: 4, height: 4))
            p.addEllipse(in: CGRect(x: 4.5, y: 16.5, width: 4, height: 4))
            p.addEllipse(in: CGRect(x: 15.5, y: 6.5, width: 4, height: 4))
            p.move(to: CGPoint(x: 6.5, y: 7.5))
            p.addLine(to: CGPoint(x: 6.5, y: 16.5))
            p.move(to: CGPoint(x: 17.5, y: 10.5))
            p.addQuadCurve(to: CGPoint(x: 6.5, y: 14), control: CGPoint(x: 17.5, y: 14))

        case .archive:
            p.addRoundedRect(in: CGRect(x: 2.5, y: 4, width: 19, height: 4.5), cornerSize: CGSize(width: 1.2, height: 1.2))
            p.move(to: CGPoint(x: 4.5, y: 8.5))
            p.addLine(to: CGPoint(x: 4.5, y: 19))
            p.addQuadCurve(to: CGPoint(x: 6, y: 20.5), control: CGPoint(x: 4.5, y: 20.5))
            p.addLine(to: CGPoint(x: 18, y: 20.5))
            p.addQuadCurve(to: CGPoint(x: 19.5, y: 19), control: CGPoint(x: 19.5, y: 20.5))
            p.addLine(to: CGPoint(x: 19.5, y: 8.5))
            p.move(to: CGPoint(x: 10, y: 13))
            p.addLine(to: CGPoint(x: 14, y: 13))
        }

        return p
    }
}
