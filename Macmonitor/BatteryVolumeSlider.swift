//
//  BatteryVolumeSlider.swift — battery-shaped system-volume slider (MEDIA group)
//  Replaces the Vol−/Vol+ buttons. Drag/tap anywhere on the battery to set volume.
//  Spans ~4 launcher buttons wide. Uses `set volume` (no special permission).
//

import SwiftUI
import Combine

struct BatteryVolumeSlider: View {
    @State private var vol: Double = 50          // 0…100
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let nubW: CGFloat = 5
            let bodyW = max(geo.size.width - nubW - 3, 10)
            let h = geo.size.height
            HStack(spacing: 3) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 5)
                        .fill(fillColor)
                        .frame(width: max(4, bodyW * CGFloat(vol / 100)))
                    Text("\(Int(vol.rounded()))")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                    RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.55), lineWidth: 1.5)
                }
                .frame(width: bodyW, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { g in
                        let x = min(max(g.location.x, 0), bodyW)
                        let v = Int((Double(x / bodyW) * 100).rounded())
                        vol = Double(v)
                        AppDelegate.shared?.setVolume(to: v)
                    }
                )
                // battery terminal nub
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.55))
                    .frame(width: nubW, height: h * 0.42)
            }
        }
        .frame(height: 22)
        .onAppear(perform: reload)
        .onReceive(tick) { _ in reload() }
    }

    private var fillColor: Color {
        vol < 20 ? .red : (vol < 50 ? .yellow : .green)
    }
    private func reload() {
        if let v = AppDelegate.shared?.currentVolume() { vol = Double(v) }
    }
}
