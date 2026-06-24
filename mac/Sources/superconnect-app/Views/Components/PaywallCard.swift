import SwiftUI

/// Reusable 会员 / paywall card: a `TierBadge` + a perk list (each perk live-locked/unlocked) + an
/// optional account-verified seal + a single CTA. Pure View leaf — it owns NO entitlement logic and
/// reads NO service; the host view passes in the tier, the perks (already resolved to locked/unlocked
/// against whatever entitlement source exists), the verified flag, and the CTA closure. This keeps the
/// free core decoupled from the (separately-authored, paid) entitlement layer: drop this card in and
/// feed it booleans when that layer lands, without this file ever importing it.
struct PaywallCard: View {
    /// Membership tier shown in the badge. Display-only; the gating decision lives in the caller.
    enum Tier {
        case free, supporter

        var label: String {
            switch self {
            case .free:      return "免费版"
            case .supporter: return "会员"
            }
        }
        /// Paid accent (pink) for the supporter tier; calm secondary for free — per the shared token set.
        var tint: Color {
            switch self {
            case .free:      return .secondary
            case .supporter: return .pink
            }
        }
        var symbol: String {
            switch self {
            case .free:      return "person"
            case .supporter: return "crown.fill"
            }
        }
    }

    /// One perk row: a title, a short caption, and whether the current entitlement unlocks it.
    struct Perk: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let unlocked: Bool
    }

    let tier: Tier
    let perks: [Perk]
    /// True when the user's account is verified (the seal). Read-only flag supplied by the caller.
    var accountVerified: Bool = false
    /// CTA title + action. nil hides the button (e.g. already at the top tier with nothing to upsell).
    var cta: (title: String, run: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TierBadge(tier: tier)
                Spacer()
                if accountVerified {
                    Label("已验证", systemImage: "checkmark.seal.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(perks) { perk in perkRow(perk) }
            }

            if let cta {
                Button(cta.title, action: cta.run)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.pink.opacity(0.06))
        )
    }

    /// One perk line: a lock/unlock glyph, the perk title, and a `.tertiary` caption.
    private func perkRow(_ perk: Perk) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: perk.unlocked ? "checkmark.circle.fill" : "lock.fill")
                .foregroundStyle(perk.unlocked ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(perk.title)
                    .foregroundStyle(perk.unlocked ? .primary : .secondary)
                Text(perk.detail)
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The tier pill used at the head of `PaywallCard` (and reusable elsewhere). Icon + label, tinted by
/// the tier; pink = paid accent, gray = free — matching the shared color token set.
struct TierBadge: View {
    let tier: PaywallCard.Tier

    var body: some View {
        Label(tier.label, systemImage: tier.symbol)
            .labelStyle(.titleAndIcon)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tier.tint.opacity(0.18)))
            .foregroundStyle(tier.tint)
    }
}
