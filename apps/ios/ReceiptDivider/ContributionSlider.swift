import SwiftUI
import UIKit

/// The unit the contribution sliders count in; chosen in Settings. Values are always stored in cents.
enum ContributionSliderUnit: String, CaseIterable, Identifiable {
    case dollars, percent
    static let storageKey = "contributionSliderUnit"
    var id: Self { self }
    var title: String { self == .dollars ? "Dollars" : "Percent" }
}

/// A system slider over 0…`total` cents with a native tick at `detent` (the person's equal share). Dragging near the
/// tick snaps onto it with a firm haptic; the snap holds until the drag moves a little further away. Every whole dollar
/// (or whole percent of the total, per the Settings unit) crossed during a drag gives a light selection tick.
struct ContributionSlider: View {
    let name: String
    @Binding var cents: Int
    let total: Int
    let detent: Int
    @AppStorage(ContributionSliderUnit.storageKey) private var unit: ContributionSliderUnit = .dollars

    var body: some View {
        HStack(spacing: 12) {
            SystemSlider(cents: $cents, total: total, detent: detent, unit: unit, label: "\(name)’s contribution",
                         valueText: format(cents), hint: "Equal share is \(format(detent))")
            Text(format(cents)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }

    private func format(_ value: Int) -> String {
        switch unit {
        case .dollars: value.usd
        case .percent: (total > 0 ? Double(value) / Double(total) : 0).formatted(.percent.precision(.fractionLength(0)))
        }
    }
}

/// `UISlider` rather than SwiftUI's `Slider`: both are Liquid Glass on iOS 26, but a SwiftUI slider with ticks only
/// allows tick values, so with a single tick at the equal share it always springs back there. UIKit's track
/// configuration can turn that off. The slider runs over 0…1 and is mapped to cents here.
private struct SystemSlider: UIViewRepresentable {
    @Binding var cents: Int
    let total: Int
    let detent: Int
    let unit: ContributionSliderUnit
    let label: String
    let valueText: String
    let hint: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.isContinuous = true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.began), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.ended), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if #available(iOS 26.0, *), coordinator.configuredFor != [total, detent] {
            slider.trackConfiguration = .init(allowsTickValuesOnly: false, ticks: [.init(position: fraction(detent))])
            coordinator.configuredFor = [total, detent]
        }
        // While dragging, the thumb follows the finger; move it only when the contribution was changed by something
        // other than this drag, such as another slider rebalancing it or the balancer capping it.
        if !slider.isTracking || cents != coordinator.lastReported, abs(slider.value - fraction(cents)) > 0.5 / Float(max(total, 1)) {
            slider.value = fraction(cents)
        }
        slider.accessibilityLabel = label
        slider.accessibilityValue = valueText
        slider.accessibilityHint = hint
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: uiView.intrinsicContentSize.height)
    }

    fileprivate func fraction(_ value: Int) -> Float { total > 0 ? Float(value) / Float(total) : 0 }

    /// The whole dollar or whole percent `value` falls in; a change between updates means a unit boundary was crossed.
    fileprivate func unitIndex(_ value: Int) -> Int {
        switch unit {
        case .dollars: value / 100
        case .percent: total > 0 ? value * 100 / total : 0
        }
    }

    @MainActor final class Coordinator: NSObject {
        static let minimumTickInterval: TimeInterval = 0.03
        var parent: SystemSlider
        var configuredFor: [Int] = []
        /// The last contribution this slider wrote, to tell its own updates from outside ones.
        var lastReported: Int?
        private var isSnapped = false
        private var lastUnit = 0
        private var lastTick = Date.distantPast
        private let detentFeedback = UIImpactFeedbackGenerator(style: .rigid)
        private let unitFeedback = UISelectionFeedbackGenerator()

        init(_ parent: SystemSlider) { self.parent = parent }

        /// Snap within 3% of the total, release beyond 4.5% so the detent holds against small finger jitter.
        private var snapRange: Int { max(1, parent.total * 3 / 100) }
        private var releaseRange: Int { max(1, parent.total * 9 / 200) }

        @objc func began(_ slider: UISlider) {
            detentFeedback.prepare()
            unitFeedback.prepare()
            isSnapped = parent.cents == parent.detent
            lastUnit = parent.unitIndex(parent.cents)
            lastReported = parent.cents
        }

        /// Snaps onto the detent with one firm haptic each time the value enters the snap zone, and gives a light tick
        /// when a whole unit is crossed, rate-limited so a fast fling doesn't turn into a buzz.
        @objc func changed(_ slider: UISlider) {
            let total = parent.total, detent = parent.detent
            let raw = min(max(Int((Double(slider.value) * Double(total)).rounded()), 0), total)
            let distance = abs(raw - detent)
            let snapped = isSnapped ? distance <= releaseRange : distance <= snapRange
            let next = snapped ? detent : raw
            let unitNow = parent.unitIndex(next)
            if snapped && !isSnapped {
                detentFeedback.impactOccurred(intensity: 1)
                lastTick = .now
            } else if !snapped, unitNow != lastUnit, Date.now.timeIntervalSince(lastTick) >= Self.minimumTickInterval {
                unitFeedback.selectionChanged()
                lastTick = .now
            }
            isSnapped = snapped
            lastUnit = unitNow
            detentFeedback.prepare()
            unitFeedback.prepare()
            lastReported = next
            if parent.cents != next { parent.cents = next }
        }

        /// Lets go on the tick when released inside the snap zone.
        @objc func ended(_ slider: UISlider) {
            if isSnapped { UIView.animate(withDuration: 0.15) { slider.setValue(self.parent.fraction(self.parent.detent), animated: true) } }
            lastReported = nil
        }
    }
}
