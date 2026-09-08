import SwiftUI

// MARK: - Model

/// One transient message.
///
/// Port of `Windows/CFS-RFID/Toast.cs`. What is kept: the two durations (2 s / 3.5 s), the
/// bottom-centre position, the one-at-a-time rule, and the error/normal split. What is dropped:
/// the borderless `TopMost` `Form`, the DWM rounded-corner P/Invoke, and the hand-rolled 10 ms
/// fade timers — an in-window overlay with a SwiftUI transition does all of that natively.
///
/// What is *added*: a VoiceOver announcement. On Windows a toast is the app's only success/error
/// channel and a screen reader never sees it (`SPEC/03-ui.md` §8.3).
struct ToastMessage: Identifiable, Equatable {
    enum Style: Equatable {
        case info
        case success
        case warning
        case error

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }

        /// Prefixed to the VoiceOver announcement so severity is not conveyed by colour alone.
        var spokenPrefix: String {
            switch self {
            case .info: return ""
            case .success: return "Success. "
            case .warning: return "Warning. "
            case .error: return "Error. "
            }
        }
    }

    let id = UUID()
    let text: String
    let style: Style
    let duration: TimeInterval

    init(_ text: String, style: Style = .info, duration: TimeInterval? = nil) {
        self.text = text
        self.style = style
        // `Toast.cs` uses LENGTH_LONG for errors and LENGTH_SHORT for everything else.
        self.duration = duration ?? (style == .error ? Theme.toastLong : Theme.toastShort)
    }

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool { lhs.id == rhs.id }
}

// MARK: - Center

/// Holds the single visible toast. Inject once at the root and read it anywhere.
///
/// One-at-a-time, matching `Toast.currentToastInstance` (`Toast.cs:146-149`): showing a new
/// message replaces the current one rather than stacking.
@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var current: ToastMessage?

    private var dismissTask: Task<Void, Never>?

    init() {}

    func show(_ message: ToastMessage) {
        dismissTask?.cancel()
        current = message
        AccessibilityNotification.Announcement(message.style.spokenPrefix + message.text).post()

        let id = message.id
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(message.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.current?.id == id else { return }
            self.current = nil
        }
    }

    // Convenience spellings so call sites read like the Windows ones.
    func info(_ text: String) { show(ToastMessage(text, style: .info)) }
    func success(_ text: String) { show(ToastMessage(text, style: .success)) }
    func warning(_ text: String) { show(ToastMessage(text, style: .warning)) }
    func error(_ text: String) { show(ToastMessage(text, style: .error)) }
    func error(_ error: Error) { show(ToastMessage(error.localizedDescription, style: .error)) }

    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

// MARK: - Environment

private struct ToastCenterKey: EnvironmentKey {
    // Optional so there is no default instance to construct off the main actor. A view that is
    // rendered outside a `ToastPresenter` (a preview, say) simply has nowhere to post and does
    // not crash. The `@EnvironmentObject` form below is the primary spelling.
    static let defaultValue: ToastCenter? = nil
}

extension EnvironmentValues {
    /// The toast channel for the current scene, or nil outside a ``ToastPresenter``.
    /// Set automatically by the `.toast(_:)` modifier.
    var toastCenter: ToastCenter? {
        get { self[ToastCenterKey.self] }
        set { self[ToastCenterKey.self] = newValue }
    }
}

// MARK: - Presenter

/// The view modifier that renders the toast overlay and publishes the center into the
/// environment. Attach it once, at the root of a scene.
struct ToastPresenter: ViewModifier {
    @ObservedObject var center: ToastCenter

    func body(content: Content) -> some View {
        content
            .environment(\.toastCenter, center)
            .environmentObject(center)
            .overlay(alignment: .bottom) {
                if let toast = center.current {
                    ToastCapsule(toast: toast) { center.dismiss() }
                        .padding(.bottom, Theme.Spacing.xl)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: center.current?.id)
    }
}

/// The capsule itself. Icon + text, never colour alone.
private struct ToastCapsule: View {
    let toast: ToastMessage
    let dismiss: () -> Void

    private var tint: Color {
        switch toast.style {
        case .info: return Theme.accent
        case .success: return Theme.success
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: toast.style.symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(toast.text)
                .font(.callout)
                .foregroundStyle(Theme.label)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadiusLarge)
                .strokeBorder(tint.opacity(0.45), lineWidth: Theme.hairline)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.style.spokenPrefix + toast.text)
        .accessibilityHint("Click to dismiss")
        .accessibilityAddTraits(.isButton)
        .help("Click to dismiss")
    }
}

// MARK: - View sugar

extension View {
    /// Attaches the toast overlay for `center` and publishes it into the environment.
    func toast(_ center: ToastCenter) -> some View {
        modifier(ToastPresenter(center: center))
    }
}
