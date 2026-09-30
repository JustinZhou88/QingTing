import Foundation

/// Integer-ratio upsampler (polyphase FIR), processed block by block, safe for the real-time thread.
/// Some devices capture at only 16 or 24 kHz once hearing aids are connected (16 kHz on an iPhone 13 mini),
/// while DeepFilterNet and RNNoise only accept 48 kHz, so the audio is upsampled to 48 kHz before noise reduction.
final class Upsampler {
    let factor: Int
    /// Taps per phase. The filter delay is tapsPerPhase/2 input samples (about 0.5 ms at 16 kHz)
    private let tapsPerPhase = 16
    private var phases: [[Float]]
    private var history: [Float]
    private var pos = 0

    /// Supported integer factor: 48000 / input sample rate. Returns nil when the ratio is not an integer.
    static func factor(from sampleRate: Double, to target: Double = 48000) -> Int? {
        let f = target / sampleRate
        guard f >= 1, abs(f - f.rounded()) < 1e-6, f <= 8 else { return nil }
        return Int(f.rounded())
    }

    init(factor: Int) {
        self.factor = factor
        let taps = tapsPerPhase
        let n = taps * factor
        // Hann-windowed sinc low-pass with the cutoff at 0.9x the input Nyquist frequency
        var h = [Float](repeating: 0, count: n)
        let center = Double(n - 1) / 2, cutoff = 0.9 / Double(factor)
        for i in 0..<n {
            let x = Double(i) - center
            let sinc = x == 0 ? cutoff : sin(Double.pi * cutoff * x) / (Double.pi * x)
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            h[i] = Float(sinc * window * Double(factor))
        }
        // Split into `factor` phases: phase p uses h[p], h[p+factor], ...
        phases = (0..<factor).map { p in (0..<taps).map { h[p + $0 * factor] } }
        history = [Float](repeating: 0, count: taps)
    }

    /// `count` input samples -> `count * factor` output samples.
    func process(_ input: UnsafePointer<Float>, count: Int, into output: UnsafeMutablePointer<Float>) {
        let taps = tapsPerPhase
        history.withUnsafeMutableBufferPointer { hist in
            for i in 0..<count {
                hist[pos] = input[i]
                pos = (pos + 1) % taps
                for p in 0..<factor {
                    var acc: Float = 0
                    // The newest sample corresponds to tap 0
                    phases[p].withUnsafeBufferPointer { ph in
                        var idx = pos - 1
                        for k in 0..<taps {
                            if idx < 0 { idx += taps }
                            acc += ph[k] * hist[idx]
                            idx -= 1
                        }
                    }
                    output[i * factor + p] = acc
                }
            }
        }
    }
}
