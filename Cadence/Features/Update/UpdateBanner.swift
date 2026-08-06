import SwiftUI

/// The update prompt. Appears only when there is something to say, so the
/// normal state of the app is no banner at all.
struct UpdateBanner: View {
    @Environment(Updater.self) private var updater

    @State private var showsNotes = false

    var body: some View {
        Group {
            switch updater.state {
            case .available(let release):
                available(release)
            case .downloading(let received, let total):
                progress(received: received, total: total)
            case .installing:
                busy("Installing — Cadence will relaunch")
            case .upToDate:
                notice("Cadence \(updater.currentVersion) is the latest version.", isError: false)
            case .failed(let message):
                notice(message, isError: true)
            case .idle, .checking:
                EmptyView()
            }
        }
        .animation(.default, value: updater.state)
    }

    // MARK: - States

    private func available(_ release: AppRelease) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 1) {
                Text("Cadence \(release.version.description) is available")
                    .font(.callout.weight(.medium))
                Text("You have \(updater.currentVersion.description). Your tasks are "
                     + "backed up before updating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("What's New") { showsNotes = true }
            Button("Skip") { updater.skip(release) }
            Button("Update & Relaunch") {
                Task { await updater.install(release) }
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .sheet(isPresented: $showsNotes) { ReleaseNotesSheet(release: release) }
    }

    private func progress(received: Int64, total: Int64) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: total > 0 ? Double(received) / Double(total) : 0)
                .frame(width: 140)
            Text(total > 0
                 ? "Downloading — \(byteCount(received)) of \(byteCount(total))"
                 : "Downloading — \(byteCount(received))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func notice(_ text: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(text).font(.callout)
            Spacer()
            Button("Dismiss") { updater.dismiss() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct ReleaseNotesSheet: View {
    var release: AppRelease

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(release.name).font(.headline)

            ScrollView {
                Text(markdown)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            HStack {
                Link("Open on GitHub", destination: release.pageURL)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560, height: 460)
    }

    private var markdown: AttributedString {
        (try? AttributedString(
            markdown: release.notes,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(release.notes)
    }
}
