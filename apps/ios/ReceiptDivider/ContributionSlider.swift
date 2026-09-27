import SwiftUI
import UIKit

/// The unit the contribution sliders lead with; chosen in Settings. Both units are always shown, with this one on top
/// and the other beneath it, and this one snaps more firmly. Values are always stored in cents.
enum ContributionSliderUnit: String, CaseIterable, Identifiable {
    case dollars, percent
    static let storageKey = "contributionSliderUnit"
    var id: Self { self }
    var title: String { self == .dollars ? "Dollars" : "Percent" }
    var other: Self { self == .dollars ? .percent : .dollars }
}

/// A system slider over 0…`total` cents with a native tick at `detent` (the person's equal share), showing the
/// contribution in the Settings unit with the other unit beneath it. Dragging is magnetic in three tiers, sized in
/// points of drag so they feel the same whatever the total: the equal share pulls hardest, then every whole unit in the
/// Settings unit, then faintly every whole unit in the other. Outside those zones the value moves freely to the cent.
struct ContributionSlider: View {
    let name: String
    @Binding var cents: Int
    let total: Int
    let detent: Int
    @AppStorage(ContributionSliderUnit.storageKey) private var unit: ContributionSliderUnit = .dollars

    var body: some View {
        HStack(spacing: 12) {
            SystemSlider(cents: $cents, total: total, detent: detent, unit: unit, label: "\(name)’s contribution",
                         valueText: "\(format(cents, in: unit)), \(format(cents, in: unit.other))",
                         hint: "Equal share is \(format(detent, in: unit))")
            VStack(alignment: .trailing, spacing: 0) {
                Text(format(cents, in: unit)).font(.subheadline)
                Text(format(cents, in: unit.other)).font(.caption2).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .frame(minWidth: 64, alignment: .trailing)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }

    private func format(_ value: Int, in unit: ContributionSliderUnit) -> String {
        switch unit {
        case .dollars: value.usd
        case .percent: (total > 0 ? Double(value) / Double(total) : 0).formatted(.percent.precision(.fractionLength(0)))
        }
    }
}

/// `UISlider` rather than SwiftUI's `Slider`: both are Liquid Glass on iOS 26, but a SwiftUI slider with ticks only
/// allows tick values, so with a single tick at the equal share it always springs back there. UIKit's track
/// configuration can turn that off. The slider runs over 0…1 and is mapped to cents here, where the raw drag position
/// is also pulled onto snap points before it's written to the binding.
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

    /// The snap tiers, strongest first. Zones are half-widths in points of drag. A unit tier's zone shrinks when its
    /// snap points are packed closely enough that the slider would otherwise feel sticky everywhere, and switches off
    /// when that leaves under a point.
    fileprivate enum Tier {
        case nominal, primary, secondary
        /// Capture half-width in points, before crowding.
        var zone: CGFloat { switch self { case .nominal: 14; case .primary: 5; case .secondary: 2.5 } }
        /// The most of the gap between neighbouring snap points a zone may take, so free travel remains between them.
        var crowdingLimit: CGFloat { switch self { case .nominal: 1; case .primary: 0.2; case .secondary: 0.1 } }
    }

    fileprivate struct Snap: Equatable { let tier: Tier; let cents: Int }

    @MainActor final class Coordinator: NSObject {
        static let minimumTickInterval: TimeInterval = 0.03
        /// Once on the equal share, the drag has to move this far to pull off it (further than the capture zone), so
        /// the detent holds against small finger jitter.
        static let nominalRelease: CGFloat = 20
        var parent: SystemSlider
        var configuredFor: [Int] = []
        /// The last contribution this slider wrote, to tell its own updates from outside ones.
        var lastReported: Int?
        private var snap: Snap?
        private var lastUnit = 0
        private var lastTick = Date.distantPast
        /// Points of thumb travel per cent, measured when the drag starts.
        private var pointsPerCent: CGFloat = 1
        private let nominalFeedback = UIImpactFeedbackGenerator(style: .rigid)
        private let primaryFeedback = UIImpactFeedbackGenerator(style: .light)
        private let secondaryFeedback = UIImpactFeedbackGenerator(style: .soft)
        private let unitFeedback = UISelectionFeedbackGenerator()

        init(_ parent: SystemSlider) { self.parent = parent }

        private func prepareFeedback() {
            [nominalFeedback, primaryFeedback, secondaryFeedback].forEach { $0.prepare() }
            unitFeedback.prepare()
        }

        @objc func began(_ slider: UISlider) {
            prepareFeedback()
            let track = slider.trackRect(forBounds: slider.bounds)
            let thumb = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: 0).width
            pointsPerCent = max(slider.bounds.width - thumb, 1) / CGFloat(max(parent.total, 1))
            snap = parent.cents == parent.detent ? Snap(tier: .nominal, cents: parent.detent) : nil
            lastUnit = parent.unitIndex(parent.cents)
            lastReported = parent.cents
        }

        /// Pulls the raw drag onto the strongest snap it's within, with a haptic matching that snap's tier on entry. Whole
        /// units crossed without snapping (a fling, or units too dense to snap) give a light rate-limited tick instead.
        @objc func changed(_ slider: UISlider) {
            let total = parent.total
            let raw = min(max(Int((Double(slider.value) * Double(total)).rounded()), 0), total)
            let nextSnap = snap(for: raw)
            let next = nextSnap?.cents ?? raw
            let unitNow = parent.unitIndex(next)
            if let nextSnap, nextSnap != snap {
                switch nextSnap.tier {
                case .nominal: nominalFeedback.impactOccurred(intensity: 1)
                case .primary: primaryFeedback.impactOccurred(intensity: 0.8)
                case .secondary: secondaryFeedback.impactOccurred(intensity: 0.4)
                }
                lastTick = .now
            } else if nextSnap == nil, snap == nil, unitNow != lastUnit, Date.now.timeIntervalSince(lastTick) >= Self.minimumTickInterval {
                unitFeedback.selectionChanged()
                lastTick = .now
            }
            snap = nextSnap
            lastUnit = unitNow
            prepareFeedback()
            lastReported = next
            if parent.cents != next { parent.cents = next }
        }

        /// Settles the thumb onto the snap point when released inside a snap zone.
        @objc func ended(_ slider: UISlider) {
            if let snap { UIView.animate(withDuration: 0.15) { slider.setValue(self.parent.fraction(snap.cents), animated: true) } }
            lastReported = nil
        }

        /// The snap `raw` falls in, if any. The equal share wins wherever zones overlap and holds over a wider release
        /// zone once caught; otherwise the nearer of the primary and secondary unit snaps whose zones contain `raw`.
        /// Unit snaps inside the equal share's capture zone are dropped so nothing competes with it.
        private func snap(for raw: Int) -> Snap? {
            let detent = parent.detent
            let nominalZone = snap?.tier == .nominal ? Self.nominalRelease : Tier.nominal.zone
            if points(abs(raw - detent)) <= nominalZone { return Snap(tier: .nominal, cents: detent) }
            let candidates = [(Tier.primary, parent.unit), (.secondary, parent.unit.other)].compactMap { tier, unit -> Snap? in
                guard let point = nearestUnit(to: raw, in: unit) else { return nil }
                let zone = min(tier.zone, points(unitSpacing(in: unit)) * tier.crowdingLimit)
                guard zone >= 1, points(abs(raw - point)) <= zone, points(abs(point - detent)) > Tier.nominal.zone else { return nil }
                return Snap(tier: tier, cents: point)
            }
            return candidates.min { abs($0.cents - raw) < abs($1.cents - raw) }
        }

        private func points(_ cents: Int) -> CGFloat { CGFloat(cents) * pointsPerCent }

        private func unitSpacing(in unit: ContributionSliderUnit) -> Int {
            switch unit {
            case .dollars: 100
            case .percent: max(parent.total / 100, 1)
            }
        }

        /// The whole dollar or whole percent of the total nearest `raw`, in cents.
        private func nearestUnit(to raw: Int, in unit: ContributionSliderUnit) -> Int? {
            let total = parent.total
            guard total > 0 else { return nil }
            let point: Int
            switch unit {
            case .dollars: point = Int((Double(raw) / 100).rounded()) * 100
            case .percent:
                let percent = (Double(raw) * 100 / Double(total)).rounded()
                point = Int((percent * Double(total) / 100).rounded())
            }
            return (0...total).contains(point) ? point : nil
        }
    }
}
