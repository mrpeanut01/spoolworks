import SwiftUI

/// Which mode the tag screen is in.
///
/// This is a **mode**, not an action. Selecting a side changes what the whole screen shows; it
/// never touches the tag. Reading is performed by Read mode's primary button (and ⌘R); writing by
/// Write mode's primary button (and ⇧⌘W), which always goes through the confirmation sheet.
enum TagMode: String, CaseIterable, Identifiable, Hashable {
    case read
    case write

    var id: String { rawValue }
    var title: String { self == .read ? "Read" : "Write" }
    var symbol: String { self == .read ? "tray.and.arrow.down" : "tray.and.arrow.up" }

    var help: String {
        self == .read
            ? "Show what is on the tag that is on the reader"
            : "Compose the values to write to a tag"
    }
}

/// A two-position sliding switch that selects the tag screen's mode.
///
/// The Windows app used a pair of buttons plus its own custom `SwitchCheckBox` elsewhere; this
/// merges the two ideas into one control. The thumb physically slides between sides so the current
/// mode is legible at a glance rather than inferred from which button looks emphasised.
///
/// **Always enabled.** An earlier revision disabled a side when the reader could not act on it, so
/// with no tag on the reader the control went dead and the write form was unreachable. A mode is
/// not an action: composing a write is meaningful with an empty reader, and "what is this screen
/// showing" must never depend on what is sitting on the antenna. Whether the *action* can run is
/// stated next to the action button, where it belongs.
///
/// Safety: sliding to **Write** shows the write form. It writes nothing, and it does not open the
/// confirmation sheet — a slide is far too easy a gesture to let it commit bytes (DECISIONS D-006).
struct TagActionSwitch: View {
    @Binding var selection: TagMode

    @Namespace private var thumb

    private let height: CGFloat = 30
    private let segmentWidth: CGFloat = 92

    var body: some View {
        HStack(spacing: 0) {
            ForEach(TagMode.allCases) { mode in
                segment(mode)
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.surfaceRecessed)
                .overlay(Capsule(style: .continuous).strokeBorder(Theme.separator, lineWidth: Theme.hairline))
        )
        .animation(.snappy(duration: 0.22), value: selection)
        // One accessibility element, not two buttons: VoiceOver should hear a switch with a
        // value, and be able to flick between sides.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tag mode")
        .accessibilityValue(selection.title)
        .accessibilityHint("Switches the screen between reading a tag and composing a write")
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { direction in
            let next: TagMode = direction == .increment ? .write : .read
            guard next != selection else { return }
            selection = next
        }
        // Arrow keys move the switch when it has focus.
        .onMoveCommand { direction in
            switch direction {
            case .left where selection != .read: selection = .read
            case .right where selection != .write: selection = .write
            default: break
            }
        }
        .focusable()
    }

    private func segment(_ mode: TagMode) -> some View {
        let selected = selection == mode

        return Button {
            selection = mode
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.symbol)
                    .imageScale(.small)
                Text(mode.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
            }
            .frame(width: segmentWidth, height: height)
            .foregroundStyle(foreground(selected: selected))
            .background {
                if selected {
                    Capsule(style: .continuous)
                        .fill(mode == .write ? Theme.accent : Theme.surface)
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        // The thumb is one view moved between sides, so it slides rather
                        // than cross-fading.
                        .matchedGeometryEffect(id: "thumb", in: thumb)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(mode.help)
    }

    private func foreground(selected: Bool) -> Color {
        guard selected else { return Theme.secondaryLabel }
        return selection == .write ? .white : Theme.label
    }
}
