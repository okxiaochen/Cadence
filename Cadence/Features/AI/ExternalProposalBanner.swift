import SwiftUI

/// A proposal that arrived from outside the app.
///
/// An agent connected over the MCP endpoint can stage changes at any moment,
/// including while you are looking at something else entirely — so this sits
/// above the workspace rather than inside the assistant panel, which may well
/// be closed. It is a banner and not a modal on purpose: nothing has happened
/// to the database, and being interrupted by someone else's suggestion is the
/// behaviour that would make the whole endpoint not worth having.
struct ExternalProposalBanner: View {
    @Environment(AppModel.self) private var model

    @State private var isExpanded = false

    var body: some View {
        Group {
            if let proposal = model.externalProposal {
                banner(proposal)
            }
        }
        .animation(.snappy(duration: 0.2), value: model.externalProposal?.id)
    }

    private func banner(_ proposal: Proposal) -> some View {
        VStack(alignment: .leading, spacing: Metrics.regular) {
            HStack(spacing: Metrics.regular) {
                Image(systemName: "sparkles.rectangle.stack")
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 1) {
                    Text("A connected agent proposed \(proposal.changes.count) "
                         + (proposal.changes.count == 1 ? "change" : "changes"))
                        .font(.callout.weight(.medium))
                    if !proposal.summary.isEmpty {
                        Text(proposal.summary)
                            .font(Typography.rowMeta)
                            .foregroundStyle(.secondaryText)
                            .lineLimit(isExpanded ? 6 : 1)
                    }
                }

                Spacer(minLength: Metrics.regular)

                Button(isExpanded ? "Hide" : "Review") { isExpanded.toggle() }
                    .buttonStyle(.quiet)
                Button("Discard") { model.discardExternalProposal() }
                    .buttonStyle(.quiet)
                Button("Apply \(proposal.applicableChanges.count)") {
                    model.applyExternalProposal()
                }
                .buttonStyle(.quietProminent)
                .disabled(proposal.applicableChanges.isEmpty)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: Metrics.tight) {
                    ForEach(proposal.changes) { reviewed in
                        HStack(spacing: Metrics.snug) {
                            Image(systemName: reviewed.isApplicable
                                  ? "checkmark.circle" : "exclamationmark.triangle")
                                .font(.system(size: 10))
                                .foregroundStyle(reviewed.isApplicable
                                                 ? AnyShapeStyle(.secondaryText)
                                                 : AnyShapeStyle(Color.orange))
                            Text(reviewed.summary)
                                .font(Typography.rowMeta)
                                .strikethrough(!reviewed.isApplicable)
                            if let reason = reviewed.rejection {
                                Text(reason)
                                    .font(Typography.rowMeta)
                                    .foregroundStyle(.orange)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    ForEach(proposal.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.circle")
                            .font(Typography.rowMeta)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, Metrics.loose)
        .padding(.vertical, Metrics.comfortable)
        .background(.tint.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.hairline).frame(height: 1)
        }
    }
}
