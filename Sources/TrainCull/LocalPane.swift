import SwiftUI
import TraincullCore

/// The masking test, at the bottom of the editing pane: make a subject mask at a chosen
/// quality, look at it several ways, and adjust the subject, the background or the skin on
/// their own. It is here to judge whether TrainCull can finish a photo, not as a finished
/// design; nothing in it is saved with the photo yet.
struct LocalPane: View {
    @ObservedObject var session: Session

    private var mask: MaskResult? { session.currentMask }
    private var layer: LocalLayer { session.local.layers[session.localArea.rawValue] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("MASK (TEST)")
            HStack(spacing: 8) {
                Picker("", selection: $session.maskTier) {
                    ForEach(MatteTier.allCases, id: \.rawValue) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Fast: clean edges. High: hair over several background colours. Max: every strand, slowly.")
                Button(mask == nil ? "Make" : "Remake") { session.makeMask() }
                    .disabled(session.maskBusy || session.current == nil)
            }
            .padding(.horizontal, 6)
            if let status = session.maskStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(session.maskBusy ? Theme.accent : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
            if let mask = mask {
                Picker("Show", selection: Binding(get: { session.maskView }, set: { session.setMaskView($0) })) {
                    ForEach(MaskView.allCases, id: \.rawValue) { Text($0.name).tag($0) }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 6)
                Picker("", selection: Binding(get: { session.localArea }, set: { session.setLocalArea($0) })) {
                    ForEach(LocalArea.allCases.filter { $0 != .skin || mask.skin != nil }, id: \.rawValue) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 6)
                LocalRow(title: "Exposure", text: String(format: "%+.2f EV", layer.exposure), changed: layer.exposure != 0, range: -3 ... 3,
                         value: Binding(get: { layer.exposure }, set: { v in session.setLocal { $0.exposure = abs(v) < 0.02 ? 0 : v } }),
                         reset: { session.setLocal { $0.exposure = 0 } })
                LocalRow(title: "Saturation", text: String(format: "%.2f", layer.saturation), changed: layer.saturation != 1, range: 0 ... 2,
                         value: Binding(get: { layer.saturation }, set: { v in session.setLocal { $0.saturation = abs(v - 1) < 0.01 ? 1 : v } }),
                         reset: { session.setLocal { $0.saturation = 1 } })
                LocalRow(title: "Warmth", text: String(format: "%+.2f", layer.warmth), changed: layer.warmth != 0, range: -1 ... 1,
                         value: Binding(get: { layer.warmth }, set: { v in session.setLocal { $0.warmth = abs(v) < 0.01 ? 0 : v } }),
                         reset: { session.setLocal { $0.warmth = 0 } })
                Button("Save Mask Pictures") { session.saveMaskPictures() }
                    .controlSize(.small)
                    .padding(.horizontal, 6)
                    .help("Saves the mask, the skin mask and the two pictures it started from next to the raw, as PNG files")
            }
        }
    }
}

struct LocalRow: View {
    let title: String
    let text: String
    let changed: Bool
    let range: ClosedRange<Float>
    let value: Binding<Float>
    let reset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Button(action: reset) {
                    Text(text)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(changed ? Theme.accent : Theme.muted)
                }
                .buttonStyle(.plain)
                .help(changed ? "Click to return to no change" : "No change")
            }
            Slider(value: value, in: range)
                .controlSize(.small)
                .padding(.horizontal, 6)
        }
        .padding(.horizontal, 6)
    }
}
