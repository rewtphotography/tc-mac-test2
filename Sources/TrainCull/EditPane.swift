import SwiftUI

/// The editing controls: Apple's raw controls, in sections. Changes show on the image at once
/// and are saved to the photo's sidecar.
struct EditPane: View {
    @ObservedObject var session: Session

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Adjust.sections, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(section.uppercased())
                            ForEach(Adjust.controls.filter { $0.section == section }) { control in
                                ControlRow(session: session, control: control)
                            }
                        }
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

struct ControlRow: View {
    @ObservedObject var session: Session
    let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(control.title).font(.system(size: 12))
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
                   in: control.range)
                .controlSize(.small)
                .padding(.horizontal, 6)
        }
        .padding(.horizontal, 6)
    }
}
