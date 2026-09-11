import SwiftUI
import SpoolworksCore

/// A restart waiting for a print to finish, and the way to call it off.
///
/// Observes the scheduler itself: it is a plain `let` on `PrinterViewModel`, and a nested
/// `ObservableObject` does not republish through its owner.
struct PendingRestartBanner: View {
    @ObservedObject var scheduler: PrinterRestartScheduler
    let family: PrinterType

    var body: some View {
        if let pending = scheduler.pending[family] {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restart pending")
                        .font(.callout.weight(.semibold))
                    Text(scheduler.statusText(for: pending))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if pending.status != .restarting {
                    Button("Cancel Restart") { scheduler.cancel(family: family) }
                        .help("Stop waiting. The printer will not be restarted.")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.08))
            .accessibilityElement(children: .combine)
        }
    }
}
