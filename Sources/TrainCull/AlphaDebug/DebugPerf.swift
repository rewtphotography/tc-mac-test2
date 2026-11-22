#if TC_ALPHA_DEBUG
import AppKit
import Foundation
import TraincullCore

/// The automated build's performance run (-TCPerf YES, on the large made-up DNG): 50-step
/// Exposure drags at fit and at 100%, a look at 400%, then each Preview tuning setting changed
/// the way the Debug menu changes it. The status line is sampled against what is on screen all
/// along. Everything it finds is in the log ("drag", "render", "perf" lines).
enum DebugPerf {
    private static var samples = 0
    private static var mismatches: [String] = []
    private static var sampler: Timer?

    static func start(_ session: Session) {
        func whenSettled(_ timeout: Double = 120, _ then: @escaping () -> Void) {
            let started = CFAbsoluteTimeGetCurrent()
            func poll() {
                if session.folder != nil, session.settledPreview() != nil { return then() }
                if CFAbsoluteTimeGetCurrent() - started > timeout {
                    Log.warn("perf: nothing settled within \(Int(timeout)) s")
                    return then()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { poll() }
        }
        func drag(_ steps: Int, from: Float, to: Float, interval: Double = 0.02, _ then: @escaping () -> Void) {
            guard let c = Adjust.control("exposure") else { return then() }
            session.dragChanged(c, began: true)
            for i in 1 ... steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) {
                    session.setValue(c, from + (to - from) * Float(i) / Float(steps))
                    if i == steps {
                        session.dragChanged(c, began: false)
                        whenSettled { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { then() } }
                    }
                }
            }
        }
        func zoom(_ percent: CGFloat?, _ then: @escaping () -> Void) {
            guard let view = session.singleView else { return then() }
            if let p = percent { view.zoom(percent: p, spot: CGPoint(x: 0.5, y: 0.5)) } else { view.fit(animated: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { whenSettled { then() } }
        }
        func memory(_ what: String) {
            let bytes = MemoryMonitor.footprint()
            Log.note("perf", "memory \(what): \(MemoryStats.plain(bytes))",
                     fields: ["what": what, "footprintMB": Double(bytes) / 1_048_576, "tuning": PreviewTuning.current.fields])
        }
        func sequence(_ steps: [(@escaping () -> Void) -> Void], _ done: @escaping () -> Void) {
            guard let first = steps.first else { return done() }
            first { sequence(Array(steps.dropFirst()), done) }
        }

        let legacy = PreviewTuning.current.legacy
        let d = UserDefaults.standard
        if !legacy {
            // Start from the defaults whatever an earlier run left.
            for key in [PreviewTuning.keys.settle, PreviewTuning.keys.draft, PreviewTuning.keys.appleDownscale, PreviewTuning.keys.region] { d.removeObject(forKey: key) }
        }
        DispatchQueue.main.async {
            whenSettled {
                Log.note("perf", "start · \(PreviewTuning.current.text)", fields: ["tuning": PreviewTuning.current.fields])
                startSampling(session)
                memory("at fit, settled")
                var steps: [(@escaping () -> Void) -> Void] = [
                    { next in drag(50, from: 0, to: 1, next) },
                    { next in zoom(100, next) },
                    { next in drag(50, from: 1, to: 0, next) },
                    { next in zoom(400, next) },
                    { next in DispatchQueue.main.asyncAfter(deadline: .now() + 1) { memory("at 400%, settled"); next() } },
                    { next in zoom(nil, next) },
                ]
                if !legacy {
                    for delay in PreviewTuning.settleChoices {
                        steps.append { next in DebugTools.setTuning(PreviewTuning.keys.settle, delay); drag(5, from: 0, to: 0.3, next) }
                    }
                    steps.append { next in DebugTools.setTuning(PreviewTuning.keys.settle, 0.25); next() }
                    steps.append { next in DebugTools.setTuning(PreviewTuning.keys.draft, false); drag(5, from: 0.3, to: 0.6, next) }
                    steps.append { next in DebugTools.setTuning(PreviewTuning.keys.draft, true); next() }
                    steps.append { next in
                        DebugTools.setTuning(PreviewTuning.keys.appleDownscale, true)
                        drag(5, from: 0.6, to: 0.2, next)
                    }
                    steps.append { next in d.removeObject(forKey: PreviewTuning.keys.appleDownscale); DebugTools.tuningChanged("Apple's downscaling back off"); next() }
                    steps.append { next in zoom(100, next) }
                    steps.append { next in DebugTools.setTuning(PreviewTuning.keys.region, false); drag(5, from: 0.2, to: 0.5, next) }
                    steps.append { next in DebugTools.setTuning(PreviewTuning.keys.region, true); zoom(nil, next) }
                }
                sequence(steps) {
                    sampler?.invalidate()
                    Log.note("perf", "status line checked \(samples) times while a raw frame was on screen: \(mismatches.count) mismatches"
                        + (mismatches.isEmpty ? "" : " (\(mismatches.prefix(5).joined(separator: "; ")))"),
                             fields: ["samples": samples, "mismatches": mismatches.count, "tuning": PreviewTuning.current.fields])
                    Log.note("perf", "finished")
                }
            }
        }
    }

    /// Every 10 ms: the status line against what is on screen (a draft or the settled render).
    private static func startSampling(_ session: Session) {
        sampler = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            guard let kind = session.singleView?.shownKind, !kind.isEmpty else { return }
            samples += 1
            let status = session.heroStates[0]
            if status != kind { mismatches.append("status \(status) with a \(kind) frame") }
        }
    }
}
#endif
