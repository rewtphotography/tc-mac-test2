import SwiftUI
import TraincullCore

/// The masking test, at the bottom of the editing pane: make a subject mask at a chosen
/// quality, look at it several ways, and adjust the subject, the background or the skin on
/// their own. It is here to judge whether TrainCull can finish a photo, not as a finished
/// design; nothing in it is saved with the photo yet.
struct LocalPane: View {
    @ObservedObject var session: Session
    @State private var showDebug = false

    private var mask: MaskResult? { session.currentMask }
    private var layer: LocalLayer { session.local.layers[session.localArea.rawValue] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("MASK (TEST)")
            Button(mask == nil ? "Make Mask" : "Remake Mask") { session.makeMask() }
                .disabled(session.maskBusy || session.current == nil)
                .padding(.horizontal, 6)
                .help(mask == nil ? "Find the subject and make its mask" : "Find the subject again from scratch")
            Picker("Focus strictness", selection: $session.focusStrictness) {
                ForEach(FocusStrictness.allCases, id: \.rawValue) { Text($0.name).tag($0) }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6)
            .help("How readily things softer than the subject's face are left out of the mask. Takes effect on Remake.")
            if let status = session.maskStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(session.maskBusy ? Theme.accent : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
            if mask != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Tool", selection: $session.maskTool) {
                        ForEach(MaskTool.menu(withClean: session.showCleanEdge), id: \.rawValue) { Text($0.name).tag($0) }
                    }
                    .help("Refine Edges: drag a box round fingers, footwear, a gap or a prop (Shift: redraw everything in the box). Refine Hair: paint over hair. Edge Brush: paint along a hard edge. Hold Option to put the automatic mask back instead.")
                    Toggle("Show edits", isOn: $session.showEdits)
                        .help("Keeps every box and stroke made on this photo drawn over it. Off, each shows only while it is drawn and worked out.")
                    if session.maskTool != .none {
                        Text(session.maskTool.hint)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if session.maskTool == .hair || session.maskTool == .edgeBrush || session.maskTool == .clean {
                        LocalRow(title: "Brush size", text: "\(Int(session.brushSize)) px", changed: false, range: 4 ... 600,
                                 value: Binding(get: { Float(session.brushSize) }, set: { session.brushSize = Double($0) }),
                                 reset: { session.brushSize = 60 })
                            .help("The brush's radius in pixels of the photo. The [ and ] keys change it too.")
                    }
                    if session.maskTool.usesMattingModel {
                        LocalRow(title: "Strength", text: String(format: "%.2f", session.brushStrength), changed: session.brushStrength != 1, range: 0 ... 1,
                                 value: Binding(get: { Float(session.brushStrength) }, set: { session.brushStrength = Double($0) }),
                                 reset: { session.brushStrength = 1 })
                            .help("How far the matting model's answer is laid in under the stroke")
                        LocalRow(title: "Tightness", text: String(format: "%+.2f", session.brushTightness), changed: session.brushTightness != 0, range: -1 ... 1,
                                 value: Binding(get: { Float(session.brushTightness) }, set: { session.brushTightness = abs(Double($0)) < 0.03 ? 0 : Double($0) }),
                                 reset: { session.brushTightness = 0 })
                            .help("Above 0 leaves faint flyaways and grey haze out; below 0 keeps more of them")
                    }
                    if session.maskTool == .clean {
                        LocalRow(title: "Strength", text: String(format: "%.2f", session.cleanStrength), changed: session.cleanStrength != 1, range: 0 ... 1,
                                 value: Binding(get: { Float(session.cleanStrength) }, set: { session.cleanStrength = Double($0) }),
                                 reset: { session.cleanStrength = 1 })
                            .help("How far the brush may move the mask from where it was")
                        LocalRow(title: "Tightness", text: String(format: "%+.2f", session.cleanTightness), changed: session.cleanTightness != 0, range: -1 ... 1,
                                 value: Binding(get: { Float(session.cleanTightness) }, set: { session.cleanTightness = abs(Double($0)) < 0.03 ? 0 : Double($0) }),
                                 reset: { session.cleanTightness = 0 })
                            .help("Above 0 pulls the edge in towards the subject; below 0 lets it out")
                    }
                    Button(session.refineCount == 0 ? "Undo" : "Undo (\(session.refineCount))") { session.undoTool() }
                        .controlSize(.small)
                        .disabled(session.refineCount == 0 || session.maskBusy)
                        .help("Takes back the last tool operation on this photo (Command-Z while a tool is chosen)")
                }
                .font(.system(size: 12))
                .padding(.horizontal, 6)
            }
            DisclosureGroup("Debug", isExpanded: $showDebug) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Hair tier", selection: $session.maskTier) {
                        ForEach(MatteTier.allCases, id: \.rawValue) { Text($0.name).tag($0) }
                    }
                    .help("Off is the mask. Fast, High and Max add the older automatic hair matting on top, kept here only for comparison; changing this on a photo that has a mask redoes just the hair.")
                    Toggle("Edge re-centre", isOn: $session.edgeRecentre)
                        .controlSize(.small)
                        .help("The mask's edge moved onto the photo's own edge and made as wide as it, and the colours beside it read off the photo there. Off is alpha 14's edge.")
                    Toggle("Edge snap", isOn: $session.edgeSnap)
                        .controlSize(.small)
                        .help("The edge moved to where each pixel's colour puts it. Switching it remakes the edge of this photo's mask (tool operations are done again).")
                    Toggle("Decontamination", isOn: $session.decontamination)
                        .controlSize(.small)
                        .help("Edge pixels given their own colour shares, so darkening the background takes the background's light with it")
                    Toggle("Colour guard", isOn: $session.colourGuard)
                        .controlSize(.small)
                        .help("The last check that no edge pixel comes out more colourful, or a different hue, than the photo has it")
                    Toggle("Subject light bound", isOn: $session.lightBound)
                        .controlSize(.small)
                        .help("At an edge the subject keeps no light its own colour doesn't have: a green or teal fringe goes with the background. Needs Decontamination.")
                    Toggle("Automatic hands", isOn: $session.autoHands)
                        .controlSize(.small)
                        .help("Make Mask also refines each hand as a Refine Edges box would. Switching it remakes this photo's edge.")
                    Toggle("Ignore faces", isOn: $session.ignoreFaces)
                        .controlSize(.small)
                        .help("The mask is made as if no face had been found, to try the no-face path on any photo. Remakes the mask.")
                    Toggle("Clean Edge in the tool menu", isOn: $session.showCleanEdge)
                        .controlSize(.small)
                        .help("The older Clean Edge brush, replaced by the Edge Brush")
                    Picker("Hair method", selection: $session.hairMethod) {
                        ForEach(HairMethod.allCases, id: \.rawValue) { Text($0.name).tag($0) }
                    }
                    .help("Automatic: colour matting on a plain, contrasting backdrop, the matting model otherwise. The log says which ran and why.")
                    LocalRow(title: "Colour matting needs contrast", text: String(format: "%.2f", session.hairContrast), changed: session.hairContrast != 0.5, range: 0 ... 1,
                             value: Binding(get: { Float(session.hairContrast) }, set: { session.hairContrast = Double($0) }),
                             reset: { session.hairContrast = 0.5 })
                    LocalRow(title: "…and a backdrop no busier than", text: String(format: "%.2f", session.hairTexture), changed: session.hairTexture != 0.03, range: 0 ... 0.5,
                             value: Binding(get: { Float(session.hairTexture) }, set: { session.hairTexture = Double($0) }),
                             reset: { session.hairTexture = 0.03 })
                    Toggle("Legacy Vision mask", isOn: $session.legacyVision)
                        .controlSize(.small)
                        .help("Apple's Vision finds the subject instead of BiRefNet, as before alpha 9. Takes effect on Remake.")
                    Picker("Run model on", selection: $session.modelUnits) {
                        ForEach(ModelUnits.allCases, id: \.rawValue) { Text($0.name).tag($0) }
                    }
                    .help("Which processors BiRefNet runs on, for comparing memory and speed in the log. The first run on the Neural Engine can take minutes while the Mac prepares the model for it.")
                    Button("Export Debug Bundle") { session.exportDebugBundle() }
                        .controlSize(.small)
                        .disabled(session.current == nil)
                        .help("Writes a folder next to the raw with what the masking saw and decided for this photo")
                }
                .padding(.top, 4)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6)
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
                         value: Binding(get: { layer.exposure }, set: { v in session.setLocal("Exposure") { $0.exposure = abs(v) < 0.02 ? 0 : v } }),
                         reset: { session.setLocal("Exposure") { $0.exposure = 0 } })
                LocalRow(title: "Saturation", text: String(format: "%.2f", layer.saturation), changed: layer.saturation != 1, range: 0 ... 2,
                         value: Binding(get: { layer.saturation }, set: { v in session.setLocal("Saturation") { $0.saturation = abs(v - 1) < 0.01 ? 1 : v } }),
                         reset: { session.setLocal("Saturation") { $0.saturation = 1 } })
                LocalRow(title: "Warmth", text: String(format: "%+.2f", layer.warmth), changed: layer.warmth != 0, range: -1 ... 1,
                         value: Binding(get: { layer.warmth }, set: { v in session.setLocal("Warmth") { $0.warmth = abs(v) < 0.01 ? 0 : v } }),
                         reset: { session.setLocal("Warmth") { $0.warmth = 0 } })
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
