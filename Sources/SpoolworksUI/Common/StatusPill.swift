import SwiftUI

/// A compact status badge: symbol + text + tone.
///
/// The symbol and the text are both mandatory. That is deliberate — the Windows app encodes
/// reader state purely as the colour of `lblConnect` (IndianRed vs. MediumSeaGreen,
/// `MainForm.cs:308,351,368`), which is invisible to anyone with a red/green deficiency and to
/// every screen reader. Nothing in this port carries state in colour alone.
struct StatusPill: View {
    enum Tone {
        case neutral
        case active
        case good
        case caution
        case bad

        var color: Color {
            switch self {
            case .neutral: return Theme.secondaryLabel
            case .active: return Theme.accent
            case .good: return Theme.success
            case .caution: return Theme.warning
            case .bad: return Theme.danger
            }
        }
    }

    let symbol: String
    let text: String
    var tone: Tone = .neutral
    /// Shows a spinner instead of the symbol, for transient states.
    var isBusy: Bool = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(tone.color)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.label)
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.xs)
        .background(tone.color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.30), lineWidth: Theme.hairline))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(text))
    }
}

/// A labelled row whose value is monospaced and selectable, with a copy affordance.
///
/// Replaces the Windows pattern of a `Label` you have to *click* to copy
/// (`MainForm.ImgEnc_Click`, `MainForm.cs:866-875`) — an undiscoverable hidden hit target on a
/// PNG. Here the value is selectable text with a real, labelled button next to it.
struct ValueRow: View {
    let label: String
    let value: String
    var monospaced: Bool = true
    var copyable: Bool = true
    /// Extra text placed after the value, e.g. a decoded meaning.
    var annotation: String?

    @Environment(\.toastCenter) private var toasts

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Text(label)
                .font(.callout)
                .foregroundStyle(Theme.secondaryLabel)
                .frame(width: 132, alignment: .leading)

            Text(value)
                .font(monospaced ? Theme.mono : .callout)
                .textSelection(.enabled)
                .foregroundStyle(Theme.label)

            if let annotation {
                Text(annotation)
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryLabel)
            }

            Spacer(minLength: 0)

            if copyable {
                CopyButton(value: value, what: label)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)\(annotation.map { ", \($0)" } ?? "")")
    }
}

/// An icon-only copy button that still carries a full accessibility label and a tooltip.
struct CopyButton: View {
    let value: String
    let what: String

    @Environment(\.toastCenter) private var toasts

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            toasts?.success("\(what) copied to clipboard")
        } label: {
            Image(systemName: "doc.on.doc")
                .imageScale(.small)
        }
        .buttonStyle(.borderless)
        .help("Copy \(what.lowercased()) to the clipboard")
        .accessibilityLabel("Copy \(what)")
    }
}

/// A colour swatch that also states its hex value, so the colour is never the only information.
struct ColorSwatch: View {
    let color: Color
    let hex: String
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                .fill(color)
                .frame(width: size * 1.6, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadiusSmall)
                        .strokeBorder(Theme.separator, lineWidth: Theme.hairline)
                )
                .accessibilityHidden(true)
            Text("#" + hex)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.secondaryLabel)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Colour #\(hex)")
    }
}

/// A titled card. Used for the tag panel, the write form and the result panel.
struct Card<Content: View>: View {
    let title: String
    var symbol: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String,
         symbol: String? = nil,
         accessory: AnyView? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.s) {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
                Spacer(minLength: Theme.Spacing.s)
                if let accessory { accessory }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
