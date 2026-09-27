import SwiftUI

/// The unit the contribution sliders count in; chosen in Settings. Values are always stored in cents.
enum ContributionSliderUnit: String, CaseIterable, Identifiable {
    case dollars, percent
    static let storageKey = "contributionSliderUnit"
    var id: Self { self }
    var title: String { self == .dollars ? "Dollars" : "Percent" }
}

/// A system `Slider` over 0…`total` cents with a native tick at `detent` (the person's equal share). Dragging near the
/// tick snaps onto it with a firm haptic; the snap holds until the drag moves a little further away. Every whole dollar
/// (or whole percent of the total, per the Settings unit) crossed during a drag gives a light selection tick.
struct ContributionSlider: View {
    let name: String
    @Binding var cents: Int
    let total: Int
    let detent: Int
    @AppStorage(ContributionSliderUnit.storageKey) private var unit: ContributionSliderUnit = .dollars
    @State private var drag = DragState()
    @State private var snaps = 0
    @State private var ticks = 0

    /// Snap within 3% of the total, release beyond 4.5% so the detent holds against small finger jitter.
    private var snapRange: Int { max(1, total * 3 / 100) }
    private var releaseRange: Int { max(1, total * 9 / 200) }

    var body: some View {
        HStack(spacing: 12) {
            slider
            Text(valueText).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .sensoryFeedback(.impact(weight: .medium, intensity: 1), trigger: snaps)
        .sensoryFeedback(.selection, trigger: ticks)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var slider: some View {
        let bounds = 0...Double(max(total, 1))
        if #available(iOS 26.0, *) {
            Slider(value: value, in: bounds, label: { Text("\(name)’s contribution") }, ticks: {
                SliderTick(Double(detent))
            }, onEditingChanged: editingChanged)
            .accessibilityValue(valueText)
            .accessibilityHint("Equal share is \(format(detent))")
        } else {
            Slider(value: value, in: bounds, label: { Text("\(name)’s contribution") }, onEditingChanged: editingChanged)
                .accessibilityValue(valueText)
                .accessibilityHint("Equal share is \(format(detent))")
        }
    }

    private var valueText: String { format(cents) }

    private func format(_ value: Int) -> String {
        switch unit {
        case .dollars: value.usd
        case .percent: (total > 0 ? Double(value) / Double(total) : 0).formatted(.percent.precision(.fractionLength(0)))
        }
    }

    /// The whole dollar or whole percent `value` falls in; a change between updates means a unit boundary was crossed.
    private func unitIndex(_ value: Int) -> Int {
        switch unit {
        case .dollars: value / 100
        case .percent: total > 0 ? value * 100 / total : 0
        }
    }

    private var value: Binding<Double> {
        Binding(get: { Double(cents) }, set: { update(to: Int($0.rounded())) })
    }

    private func editingChanged(_ editing: Bool) {
        drag.isSnapped = editing && cents == detent
        drag.lastUnit = unitIndex(cents)
    }

    /// Clamps to the track and snaps onto the detent: one firm haptic each time the value enters the snap zone, and a
    /// light tick when a whole unit is crossed, rate-limited so a fast fling doesn't turn into a buzz.
    private func update(to raw: Int) {
        let clamped = min(max(raw, 0), total), distance = abs(clamped - detent)
        let snapped = drag.isSnapped ? distance <= releaseRange : distance <= snapRange
        let next = snapped ? detent : clamped
        let enteredSnap = snapped && !drag.isSnapped
        drag.isSnapped = snapped
        let unitNow = unitIndex(next)
        if enteredSnap {
            snaps += 1
            drag.lastTick = .now
        } else if unitNow != drag.lastUnit, !snapped, Date.now.timeIntervalSince(drag.lastTick) >= DragState.minimumTickInterval {
            ticks += 1
            drag.lastTick = .now
        }
        drag.lastUnit = unitNow
        if cents != next { cents = next }
    }
}

/// Per-drag bookkeeping kept in a reference so updating it doesn't re-render the slider.
private final class DragState {
    static let minimumTickInterval: TimeInterval = 0.03
    var isSnapped = false
    var lastUnit = 0
    var lastTick = Date.distantPast
}
