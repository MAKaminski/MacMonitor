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
            }
        }
    }
}
