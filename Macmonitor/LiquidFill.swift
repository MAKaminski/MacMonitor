//
//  LiquidFill.swift — animated "liquid" fill for bars and sliders.
//  A colored body with a gently waving leading edge and a shimmer band sweeping
//  through. Drop in as the fill; clip to a Capsule/RoundedRectangle for shape.
//

import SwiftUI

struct LiquidFill: View {
    var level: Double          // 0…1
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let lvl = max(0, min(1, level))
                let fillW = max(3, w * lvl)
                let amp = min(2.6, h * 0.22)
                let phase = t * 3.2

                // liquid body with a waving leading (right) edge
                var body = Path()
                body.move(to: CGPoint(x: 0, y: 0))
                body.addLine(to: CGPoint(x: max(0, fillW - amp), y: 0))
                var y: CGFloat = 0
                while y <= h {
                    let x = (fillW - amp) + amp * CGFloat(sin(Double(y) / Double(max(h, 1)) * .pi * 3 + phase))
                    body.addLine(to: CGPoint(x: x, y: y))
                    y += 1.5
                }
                body.addLine(to: CGPoint(x: 0, y: h))
                body.closeSubpath()

                ctx.fill(body, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.95), color.opacity(0.55)]),
                    startPoint: .zero, endPoint: CGPoint(x: fillW, y: 0)))

                // shimmer band sweeping through the liquid
                ctx.clip(to: body)
                let sx = CGFloat(t.truncatingRemainder(dividingBy: 2.2) / 2.2) * fillW
                let band = Path(CGRect(x: sx - 10, y: 0, width: 20, height: h))
                ctx.fill(band, with: .linearGradient(
                    Gradient(colors: [.clear, .white.opacity(0.30), .clear]),
                    startPoint: CGPoint(x: sx - 10, y: 0), endPoint: CGPoint(x: sx + 10, y: 0)))

                // sparkles twinkling inside the liquid
                for i in 0..<8 {
                    let seed = Double(i + 1) * 1.61803
                    let sxp = CGFloat((seed * 137.5).truncatingRemainder(dividingBy: 1.0)) * fillW
                    let syp = CGFloat((seed * 73.31).truncatingRemainder(dividingBy: 1.0)) * h
                    let tw = pow(sin(t * (1.4 + seed.truncatingRemainder(dividingBy: 0.9)) + seed * 7.0), 2)
                    guard tw > 0.45 else { continue }
                    let r: CGFloat = 0.8 + CGFloat(tw) * 1.1
                    let dot = Path(ellipseIn: CGRect(x: sxp - r, y: syp - r, width: r * 2, height: r * 2))
                    ctx.fill(dot, with: .color(.white.opacity(0.25 + 0.55 * tw)))
                }
            }
        }
    }
}

/// "LED train" — rainbow segments marching around the HUD's edge.
/// Overlay on the HUD root; hit-testing disabled by the caller.
struct HUDEdgeRainbow: View {
    var cornerRadius: CGFloat = 14
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t * 42).truncatingRemainder(dividingBy: 24))     // marching LEDs
            let spin = Angle.degrees((t * 24).truncatingRemainder(dividingBy: 360)) // cycling rainbow
            RoundedRectangle(cornerRadius: cornerRadius)
                .inset(by: 1.5)
                .stroke(
                    AngularGradient(gradient: Gradient(colors: [
                        .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red
                    ]), center: .center, angle: spin),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [9, 15], dashPhase: -phase)
                )
                .opacity(0.85)
                .shadow(color: .white.opacity(0.15), radius: 3)
        }
    }
}
