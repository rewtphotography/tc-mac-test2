import SwiftUI
import TraincullCore

/// The editing controls: Apple's raw controls in pipeline order, in sections that fold away.
/// Changes show on the image at once and are saved to the photo's sidecar.
struct EditPane: View {
    @ObservedObject var session: Session

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Adjust.sections, id: \.self) { section in
                        PanelSection(session: session, section: section)
                    }
                }
                .padding(12)
            }
            .disabled(session.defaults.isEmpty)
            Divider().overlay(Theme.line)
            VStack(spacing: 8) {
                Button("Reset All") { session.resetAll() }
                    .disabled(session.values.isEmpty)
                    .frame(maxWidth: .infinity)
                Button {
                    session.exportCurrent(.tiff)
                } label: {
                    Text("Export 16-bit TIFF").frame(maxWidth: .infinity)
                }
                .disabled(session.current == nil || session.exportStatus != nil)
                Button {
                    if let item = session.current { session.sendToEditor([item]) }
                } label: {
                    Text("Send to Photoshop").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(12)
        }
        .background(Theme.surface.opacity(0.6))
    }
}

/// One section, open by default; whether it is folded is remembered.
struct PanelSection: View {
    @ObservedObject var session: Session
    let section: String
    @AppStorage private var collapsed: Bool

    init(session: Session, section: String) {
        self.session = session
        self.section = section
        _collapsed = AppStorage(wrappedValue: false, "editSectionCollapsed.\(section)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                collapsed.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 10)
                    Text(section).font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            if !collapsed {
                ForEach(Adjust.controls.filter { $0.section == section }) { control in
                    ControlView(session: session, control: control)
                }
            }
        }
    }
}

/// The name of a control, with a red dot when Apple doesn't support it for this file.
struct ControlName: View {
    let control: Control
    let state: ControlState

    var body: some View {
        HStack(spacing: 5) {
            Text(control.title).font(.system(size: 12))
            if state.redDot {
                Circle().fill(Color.red).frame(width: 6, height: 6)
            }
        }
    }
}

struct ControlView: View {
    @ObservedObject var session: Session
    let control: Control

    var body: some View {
        let state = session.state(control)
        Group {
            switch control.kind {
            case .slider: SliderRow(session: session, control: control, state: state)
            case .toggle: ToggleRow(session: session, control: control, state: state)
            case .neutralPoint: NeutralPointRow(session: session, control: control)
            case .decoder: DecoderRow(session: session, control: control)
            }
        }
        .disabled(!state.enabled)
        .opacity(state.enabled ? 1 : 0.45)
        .help(state.enabled ? "" : RawPanel.unsupportedTip)
        .padding(.horizontal, 6)
    }
}

/// A slider. Its thumb may sit at an end when Apple's default lies outside the range; the value
/// shown, and the one Apple uses, is still Apple's own until the slider is moved.
struct SliderRow: View {
    @ObservedObject var session: Session
    let control: Control
    let state: ControlState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                ControlName(control: control, state: state)
                Spacer()
                Button { session.reset(control) } label: {
                    Text(control.show(session.value(control)))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(session.isChanged(control) ? Theme.accent : Theme.muted)
                }
                .buttonStyle(.plain)
                .help(session.isChanged(control) ? "Click to return to the default" : "The default for this photo")
            }
            Slider(value: Binding(get: { session.value(control) }, set: { session.setValue(control, $0) }),
                   in: control.range,
                   onEditingChanged: { session.dragChanged(control, began: $0) })
                .controlSize(.small)
                .padding(.horizontal, 6)
        }
    }
}

struct ToggleRow: View {
    @ObservedObject var session: Session
    let control: Control
    let state: ControlState

    var body: some View {
        HStack {
            ControlName(control: control, state: state)
            Spacer()
            Toggle("", isOn: Binding(get: { session.value(control) >= 0.5 }, set: { session.setValue(control, $0 ? 1 : 0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(session.isChanged(control) ? Theme.accent : nil)
        }
    }
}

/// White balance by point: the eyedropper. Click it, then a neutral grey in the image.
struct NeutralPointRow: View {
    @ObservedObject var session: Session
    let control: Control

    var body: some View {
        HStack {
            ControlName(control: control, state: ControlState(enabled: true, redDot: false))
            Spacer()
            Button(session.pickingNeutral ? "Cancel" : "Pick") { session.toggleNeutralPick() }
                .controlSize(.small)
                .help(session.pickingNeutral ? "Click a neutral grey in the image, or press Esc to cancel"
                                             : "Click, then click something neutral grey in the image")
        }
    }
}

/// The decoder: a label, or a menu when the file offers more than one decoder from RAW 8 on.
struct DecoderRow: View {
    @ObservedObject var session: Session
    let control: Control

    var body: some View {
        HStack {
            ControlName(control: control, state: ControlState(enabled: true, redDot: false))
            Spacer()
            switch session.decoderLine {
            case let .label(text):
                Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            case let .menu(versions):
                Picker("", selection: Binding(get: { Int(session.value(control).rounded()) },
                                              set: { session.setValue(control, Float($0)) })) {
                    ForEach(versions, id: \.self) { version in
                        Text(RawPanel.decoderName(version)).tag(RawPanel.major(version) ?? 0)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
        }
    }
}
