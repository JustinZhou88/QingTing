import Foundation

/// 4th-order Butterworth high-pass (two cascaded biquads), processed sample by sample, safe for the real-time thread.
/// Cuts low-frequency noise (air conditioning, ventilation, desk rumble) after capture and before noise reduction: in classroom recordings the noise below 250 Hz is louder than the speech,
/// which makes the denoiser think the whole signal is noisy and suppress too hard, taking consonant detail with it.
final class HighPassFilter {
    private struct Section {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var z1: Float = 0, z2: Float = 0
    }
    private var sections: [Section]

    init(cutoff: Double, sampleRate: Double) {
        // Q values of the two biquads of a 4th-order Butterworth
        sections = [0.5412, 1.3066].map { q in
            let w = 2 * Double.pi * cutoff / sampleRate
            let alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
            return Section(b0: Float((1 + c) / 2 / a0), b1: Float(-(1 + c) / a0), b2: Float((1 + c) / 2 / a0),
                           a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
        }
    }

    func process(_ x: UnsafeMutablePointer<Float>, count: Int) {
        for s in sections.indices {
            var f = sections[s]
            for i in 0..<count {
                // Transposed direct form II
                let y = f.b0 * x[i] + f.z1
                f.z1 = f.b1 * x[i] - f.a1 * y + f.z2
                f.z2 = f.b2 * x[i] - f.a2 * y
                x[i] = y
            }
            sections[s] = f
        }
    }

    func processed(_ x: [Float]) -> [Float] {
        var y = x
        y.withUnsafeMutableBufferPointer { process($0.baseAddress!, count: $0.count) }
        return y
    }
}
