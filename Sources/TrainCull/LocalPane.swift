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
                        ForEach(MaskTool.allCases, id: \.rawValue) { Text($0.name).tag($0) }
                    }
                    .help("Refine Edges: drag a box round fingers, footwear, a gap or a prop. Refine Hair: paint over hair. Clean Edge: paint along a hard edge that still has a rim. Remove Colour: click the background colour the mask took in, then drag a box over it. Hold Option to put the automatic mask back instead.")
                    Toggle("Show edits", isOn: $session.showEdits)
                        .help("Keeps every box and stroke made on this photo drawn over it. Off, each shows only while it is drawn and worked out.")
                    if session.maskTool != .none {
                        Text(session.maskTool.hint)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if session.maskTool == .hair {
                        LocalRow(title: "Brush size", text: "\(Int(session.brushSize)) px", changed: false, range: 4 ... 600,
                                 value: Binding(get: { Float(session.brushSize) }, set: { session.brushSize = Double($0) }),
                                 reset: { session.brushSize = 60 })
                            .help("The brush's radius in pixels of the photo. The [ and ] keys change it too.")
                        LocalRow(title: "Strength", text: String(format: "%.2f", session.hairStrength), changed: session.hairStrength != 0, range: 0 ... 1,
                                 value: Binding(get: { Float(session.hairStrength) }, set: { session.hairStrength = Double($0) }),
                                 reset: { session.hairStrength = 0 })
                            .help("0 only tidies and fills the edge that is there; 1 lets the stroke add strands beyond it. Moving it redoes the last stroke.")
                    }
                    if session.maskTool == .removeColour {
                        HStack(spacing: 4) {
                            let picked = !session.removeSamples.isEmpty
                            let shown = picked ? session.removeSamples : session.removeGuessed
                            if shown.isEmpty {
                                Text("Automatic: guessed from the box")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.muted)
                            }
                            ForEach(Array(shown.enumerated()), id: \.offset) { _, c in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z), opacity: 1))
                                    .frame(width: 18, height: 18)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.5), lineWidth: 1))
                            }
                            if !shown.isEmpty {
                                Text(picked ? "picked" : "auto")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Button("Clear") { session.clearRemoveSamples() }
                                .controlSize(.small)
                                .disabled(!picked)
                                .help("Forgets the colours picked: back to the automatic guess, and the last box done again")
                        }
                        LocalRow(title: "Tolerance", text: String(format: "%.3f", session.removeTolerance), changed: session.removeTolerance != 0.05, range: 0.01 ... 0.15,
                                 value: Binding(get: { Float(session.removeTolerance) }, set: { session.removeTolerance = Double($0) }),
                                 reset: { session.removeTolerance = 0.05 })
                            .help("How close to a colour to remove a pixel must be to go. Moving it does the last Remove Colour box again.")
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
                    Toggle("Edge colour from inside", isOn: $session.insideColour)
                        .controlSize(.small)
                        .help("Each edge pixel's subject colour taken from the solid subject just inside it (like Photoshop's Decontaminate Colors), and the background side's from the background just outside. Off is alpha 16's edge colour.")
                    Toggle("Bright-background edges", isOn: $session.cutBackground)
                        .controlSize(.small)
                        .disabled(!session.insideColour)
                        .help("Where the background is clearly brighter than the subject beside it, the lens's colour fringe is cut back (judged on a slightly blurred copy) and both sides of the edge repainted. Off is alpha 21's edge. Works with Edge colour from inside.")
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
