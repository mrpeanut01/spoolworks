import SwiftUI
import SpoolworksCore

/// The printer does not list the filament a tag was just written for — and the offer to fix that.
///
/// Shown on Write tag and Intake, the two screens that write tags. It observes the model itself so
/// neither screen has to: the model is a plain `let` on `AppEnvironment`, and a nested
/// `ObservableObject` does not republish through its owner.
struct FilamentPushNotice: View {
    @ObservedObject var model: FilamentPushModel

    var body: some View {
        if let subject = model.phase.subject {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                leading
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(title(subject))
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryLabel)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: Theme.Spacing.s)
                actions
            }
            .padding(Theme.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone.opacity(0.08))
            .overlay(Rectangle().strokeBorder(tone, lineWidth: 1))
            .accessibilityElement(children: .contain)
        }
    }

    private var tone: Color {
        switch model.phase {
        case .added: return Theme.success
        case .failed: return Theme.warning
        default: return Theme.accent
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch model.phase {
        case .checking, .adding:
            ProgressView().controlSize(.small)
        case .added:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(tone).accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tone).accessibilityHidden(true)
        case .idle, .missing:
            Image(systemName: "printer").foregroundStyle(tone).accessibilityHidden(true)
        }
    }

    private func title(_ subject: FilamentPushModel.Subject) -> String {
        switch model.phase {
        case .idle:
            return ""
        case .checking:
            return "Checking whether \(subject.printerName) lists \(subject.label)…"
        case .missing:
            return "\(subject.printerName) doesn't list \(subject.label) (\(subject.filamentID)) yet"
        case .adding:
            return "Adding \(subject.label) to \(subject.printerName)…"
        case .added:
            return "\(subject.label) is in \(subject.printerName)'s filament list"
        case .failed(_, .check, _):
            return "Couldn't check \(subject.printerName) for \(subject.label)"
        case .failed(_, .add, _):
            return "Couldn't add \(subject.label) to \(subject.printerName)"
        }
    }

    private var detail: String? {
        switch model.phase {
        case .missing:
            return "The CFS ignores a tag for a filament its printer doesn't list. Adding it puts that one "
                + "entry in the printer's filament list and changes nothing else; the file it replaces is "
                + "kept on the printer."
        case .added:
            // Seen on a K2 Plus: the touchscreen picked the new entry up at once, while the CFS kept
            // reporting a slot set to it as unknown. Whether a restart is what it needs is still to be
            // confirmed on hardware (D-013), so this says "may".
            return "The touchscreen lists it straight away. The CFS may not recognise the tag until the "
                + "printer restarts: when it's idle, restart it, then reload the spool."
        case let .failed(_, _, message):
            return message
        case .idle, .checking, .adding:
            return nil
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch model.phase {
        case .missing:
            HStack(spacing: Theme.Spacing.xs) {
                Button("Not now") { model.notNow() }
                    .buttonStyle(.sw(.ghost, size: 11.5, h: 10, v: 6))
                Button("Add to printer") { model.add() }
                    .buttonStyle(.sw(.primary, size: 11.5, h: 10, v: 6))
            }
        case .added:
            Button("Done") { model.dismiss() }
                .buttonStyle(.sw(.ghost, size: 11.5, h: 10, v: 6))
        case .failed:
            HStack(spacing: Theme.Spacing.xs) {
                Button("Not now") { model.notNow() }
                    .buttonStyle(.sw(.ghost, size: 11.5, h: 10, v: 6))
                Button("Try again") { model.retry() }
                    .buttonStyle(.sw(.secondary, size: 11.5, h: 10, v: 6))
            }
        case .idle, .checking, .adding:
            EmptyView()
        }
    }
}
