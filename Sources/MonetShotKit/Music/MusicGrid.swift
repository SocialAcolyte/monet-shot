import AVFoundation
import Foundation

/// A song's beat, found by ear: how long its bars are, where they start, and
/// where it lifts (a louder section coming in on a downbeat). The snippet
/// window uses it so a video starts on a downbeat, and so a lift can land on
/// a zoom.
public struct MusicGrid: Equatable, Sendable {
    /// Seconds per bar of four beats.
    public var bar: Double
    /// The first downbeat, 0 ..< bar.
    public var firstDownbeat: Double
    /// Song times of downbeats where a louder section comes in, earliest first.
    public var lifts: [Double]

    public init(bar: Double, firstDownbeat: Double, lifts: [Double]) {
        self.bar = bar; self.firstDownbeat = firstDownbeat; self.lifts = lifts
    }

    public var bpm: Double { 240 / bar }

    /// The bar line nearest `t` (never before 0).
    public func nearestBarLine(_ t: Double) -> Double {
        let k = ((t - firstDownbeat) / bar).rounded()
        let line = firstDownbeat + k * bar
        return line < 0 ? line + bar : line
    }

    /// Reads the song (mono, 11 kHz) and finds its grid; nil if it has no steady beat.
    public static func analyze(_ url: URL) async -> MusicGrid? {
        let rate = 11_025.0
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
        ])
        reader.add(out)
        guard reader.startReading() else { return nil }
        var samples: [Float] = []
        while let buffer = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
                  let ptr else { continue }
            ptr.withMemoryRebound(to: Float.self, capacity: length / 4) { s in
                samples.append(contentsOf: UnsafeBufferPointer(start: s, count: length / 4))
            }
        }
        return analyze(samples: samples, rate: rate)
    }

    /// The grid of mono samples at `rate` Hz.
    public static func analyze(samples: [Float], rate: Double) -> MusicGrid? {
        let hop = 256
        let fps = rate / Double(hop)
        let frames = samples.count / hop
        guard frames > Int(fps * 8) else { return nil }          // under 8 seconds: nothing to go on

        // loudness per frame (log energy), and onset strength: how much louder each frame got
        var loud = [Double](repeating: 0, count: frames)
        for f in 0..<frames {
            var e: Float = 0
            for i in (f * hop)..<(f * hop + hop) { e += samples[i] * samples[i] }
            loud[f] = log10(Double(e) / Double(hop) + 1e-9)
        }
        var onset = [Double](repeating: 0, count: frames)
        for f in 1..<frames { onset[f] = max(0, loud[f] - loud[f - 1]) }
        let mean = onset.reduce(0, +) / Double(frames)
        for f in 0..<frames { onset[f] = max(0, onset[f] - mean) }

        // tempo: the beat period whose echo in the onsets is strongest, favouring 80-140 bpm
        let minLag = Int(fps * 60 / 180), maxLag = Int(fps * 60 / 70)
        var best = (lag: 0, score: -Double.infinity)
        var ac = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...(maxLag + 1) {
            var s = 0.0
            for f in lag..<frames { s += onset[f] * onset[f - lag] }
            ac[lag] = s
        }
        for lag in minLag...maxLag {
            let bpm = 60 * fps / Double(lag)
            let w = exp(-pow(log2(bpm / 110), 2) / (2 * 0.6 * 0.6))
            if ac[lag] * w > best.score { best = (lag, ac[lag] * w) }
        }
        guard best.lag > 0, best.score > 0 else { return nil }
        // between frames: a parabola through the peak and its neighbours
        let l = best.lag
        let (a, b, c) = (ac[l - 1], ac[l], ac[l + 1])
        let shift = (a - 2 * b + c) != 0 ? 0.5 * (a - c) / (a - 2 * b + c) : 0
        let coarse = (Double(l) + max(-0.5, min(0.5, shift))) / fps     // seconds

        // where the beats fall: the phase whose beats sit on the most onset
        func onsetNear(_ t: Double) -> Double {
            let f = Int((t * fps).rounded())
            guard f >= 1, f < frames else { return 0 }
            return max(onset[f], onset[f - 1] * 0.5, f + 1 < frames ? onset[f + 1] * 0.5 : 0)
        }
        let duration = Double(frames) / fps
        // the autocorrelation is only good to a frame; over a whole song that drifts by beats,
        // so try periods close by (with every phase) and keep the grid that sits on the most onset
        var phase = (t: 0.0, score: -1.0)
        var period = coarse
        var p = coarse * 0.97
        while p <= coarse * 1.03 {
            for step in 0..<Int(p * fps) {
                let t0 = Double(step) / fps
                var s = 0.0, t = t0
                while t < duration { s += onsetNear(t); t += p }
                if s > phase.score { phase = (t0, s); period = p }
            }
            p += 0.0005
        }
        let beat = period

        // which beat is the downbeat: sections change on bar lines, so the right one makes
        // neighbouring bars differ most in loudness, and its beats tend to hit hardest
        let bar = beat * 4
        func barLoud(_ start: Double) -> [Double] {
            var out: [Double] = []
            var t = start
            while t + bar <= duration {
                let f0 = Int(t * fps), f1 = min(frames, Int((t + bar) * fps))
                out.append(f1 > f0 ? loud[f0..<f1].reduce(0, +) / Double(f1 - f0) : 0)
                t += bar
            }
            return out
        }
        var down = (k: 0, score: -Double.infinity)
        for k in 0..<4 {
            let start = phase.t + Double(k) * beat
            let bars = barLoud(start)
            guard bars.count > 2 else { continue }
            var contrast = 0.0
            for i in 1..<bars.count { contrast += abs(bars[i] - bars[i - 1]) }
            var hits = 0.0, t = start
            while t < duration { hits += onsetNear(t); t += bar }
            let score = contrast / Double(bars.count) * 10 + hits / max(1e-9, phase.score) * 4
            if score > down.score { down = (k, score) }
        }
        let first = (phase.t + Double(down.k) * beat).truncatingRemainder(dividingBy: bar)

        // lifts: bars at least 2 dB louder than the bar before, and not quiet themselves
        let bars = barLoud(first)
        guard !bars.isEmpty else { return MusicGrid(bar: bar, firstDownbeat: first, lifts: []) }
        let sorted = bars.sorted()
        let typical = sorted[sorted.count / 2]
        var lifts: [(t: Double, rise: Double)] = []
        for i in 1..<bars.count {
            let rise = (bars[i] - bars[i - 1]) * 10                   // log10 energy -> dB
            if rise >= 2, bars[i] >= typical - 0.15 { lifts.append((first + Double(i) * bar, rise)) }
        }
        // the strongest few, at least four bars apart
        var kept: [(t: Double, rise: Double)] = []
        for l in lifts.sorted(by: { $0.rise > $1.rise }) where kept.allSatisfy({ abs($0.t - l.t) >= bar * 4 - 0.01 }) {
            kept.append(l)
            if kept.count == 6 { break }
        }
        return MusicGrid(bar: bar, firstDownbeat: first, lifts: kept.map(\.t).sorted())
    }
}
