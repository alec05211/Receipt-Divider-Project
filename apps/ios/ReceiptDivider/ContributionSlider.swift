import SwiftUI

/// A 0…`total` cents slider with a tick at `detent` (the person's equal share). Dragging near the tick snaps
/// exactly onto it with a haptic tap; the snap is sticky until the drag moves a little further away.
struct ContributionSlider: View {
    let name: String
    @Binding var cents: Int
    let total: Int
    let detent: Int
    @State private var dragStart: Int?
    @State private var isSnapped = false
    @State private var snaps = 0

    /// Snap within 3% of the total, release beyond 4.5% so the detent holds against small finger jitter.
    private var snapRange: Int { max(1, total * 3 / 100) }
    private var releaseRange: Int { max(1, total * 9 / 200) }
    private var step: Int { max(1, total / 20) }
    private func fraction(_ value: Int) -> CGFloat { total > 0 ? CGFloat(min(max(value, 0), total)) / CGFloat(total) : 0 }

    var body: some View {
        GeometryReader { geometry in
            let thumb: CGFloat = 26, usable = max(geometry.size.width - thumb, 1)
            let x = { (value: Int) in thumb / 2 + usable * fraction(value) }
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemFill)).frame(height: 4).padding(.horizontal, thumb / 2)
                Capsule().fill(.tint).frame(width: max(0, x(cents) - thumb / 2), height: 4).offset(x: thumb / 2)
                RoundedRectangle(cornerRadius: 1).fill(isSnapped || cents == detent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 2, height: 14).offset(x: x(detent) - 1)
                Circle().fill(.white).shadow(color: .black.opacity(0.2), radius: 2, y: 1).overlay(Circle().strokeBorder(Color(.separator), lineWidth: 0.5))
                    .frame(width: thumb, height: thumb).offset(x: x(cents) - thumb / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                if dragStart == nil { dragStart = cents; isSnapped = cents == detent }
                let start = dragStart ?? cents
                update(to: start + Int((drag.translation.width / usable * CGFloat(total)).rounded()))
            }.onEnded { _ in dragStart = nil; isSnapped = false })
        }
        .frame(height: 30)
        .sensoryFeedback(.impact(weight: .medium), trigger: snaps)
        .accessibilityElement()
        .accessibilityLabel("\(name)’s contribution")
        .accessibilityValue(cents.usd)
        .accessibilityHint("Equal share is \(detent.usd)")
        .accessibilityAdjustableAction { direction in
            let target = min(max(cents + (direction == .increment ? step : -step), 0), total)
            // Stop on the equal share when stepping across it.
            cents = (min(cents, target) < detent && detent < max(cents, target)) ? detent : target
        }
    }

    /// Clamps to the track and snaps onto the detent, firing one haptic each time the value enters the snap zone.
    private func update(to raw: Int) {
        let value = min(max(raw, 0), total), distance = abs(value - detent)
        if isSnapped ? distance <= releaseRange : distance <= snapRange {
            if !isSnapped { isSnapped = true; snaps += 1 }
            if cents != detent { cents = detent }
        } else {
            isSnapped = false
            if cents != value { cents = value }
        }
    }
}
