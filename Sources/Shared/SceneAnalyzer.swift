import Accelerate
import Foundation

/// Acoustic scene analysis: estimates speech-band SNR and high-frequency loss from the last few seconds of raw capture, and derives noise reduction strength and clarity from them.
/// Method: split frames into "speech" and "pause" by their 300-3000 Hz energy, average the power spectrum of each,
/// and subtract the noise spectrum from the speech spectrum to estimate the speech itself.
final class SceneAnalyzer {
    struct Estimate {
        var speechSNR: Float      // Speech/noise over 300-4000 Hz (dB)
        var highSNR: Float        // Speech/noise over 2-5 kHz (dB)
        var tilt: Float           // Speech at 2-5 kHz relative to 300-1500 Hz (dB); more negative = duller
        var speechFraction: Float // Fraction of frames containing speech
    }

    struct Params {
        var strength: Float       // Noise reduction strength 0...1
        var clarityDB: Float      // Boost above 2 kHz
    }

    /// Level of 2-5 kHz relative to 300-1500 Hz (dB) for normal speech at close range.
    /// About -14.3 from the long-term average speech spectrum (Byrne 1994); -14.7 measured on close-talking TTS.
    static let referenceTilt: Float = -14
    /// A fixed consonant emphasis regardless of distance: telling consonants apart in noise is hard with hearing aids to begin with
    static let baseClarity: Float = 4

    let sampleRate: Double
    private let n = 1024
    private let log2n: vDSP_Length = 10
    private let fft: FFTSetup
    private var window: [Float]

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// Analyzes a stretch of audio. Returns nil when there is too little speech (nobody talking); the caller should keep its current parameters.
    func analyze(_ x: [Float]) -> Estimate? {
        let hop = n / 2
        guard x.count > n * 8 else { return nil }
        let bins = n / 2
        let hz = Float(sampleRate) / Float(n)
        func bin(_ f: Float) -> Int { min(bins - 1, Int(f / hz)) }
        var spectra: [[Float]] = []
        var vad: [Float] = []
        var re = [Float](repeating: 0, count: bins), im = re, frame = [Float](repeating: 0, count: n)
        let v0 = bin(300), v1 = bin(3000)
        var i = 0
        while i + n <= x.count {
            x.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + i, 1, window, 1, &frame, 1, vDSP_Length(n)) }
            var power = [Float](repeating: 0, count: bins)
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { m in
                    var sc = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                    frame.withUnsafeBufferPointer {
                        $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(bins)) }
                    }
                    vDSP_fft_zrip(fft, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&sc, 1, &power, 1, vDSP_Length(bins))
                }
            }
            spectra.append(power)
            vad.append(10 * log10(power[v0..<v1].reduce(0, +) + 1e-20))
            i += hop
        }
        let sorted = vad.sorted()
        let floor = sorted[sorted.count / 5]
        let speechIdx = vad.indices.filter { vad[$0] > floor + 8 }
        let noiseIdx = vad.indices.filter { vad[$0] < floor + 3 }
        guard Float(speechIdx.count) >= Float(vad.count) * 0.1, noiseIdx.count >= 5 else { return nil }

        func mean(_ idx: [Int]) -> [Float] {
            var m = [Float](repeating: 0, count: bins)
            for k in idx { vDSP_vadd(m, 1, spectra[k], 1, &m, 1, vDSP_Length(bins)) }
            var s = 1 / Float(idx.count)
            vDSP_vsmul(m, 1, &s, &m, 1, vDSP_Length(bins))
            return m
        }
        let noise = mean(noiseIdx)
        let speechPlusNoise = mean(speechIdx)
        let speech = zip(speechPlusNoise, noise).map { max($0 - $1, 1e-20) }
        func band(_ a: [Float], _ lo: Float, _ hi: Float) -> Float { a[bin(lo)..<bin(hi)].reduce(0, +) }
        func db(_ v: Float) -> Float { 10 * log10(max(v, 1e-20)) }
        return Estimate(
            speechSNR: db(band(speech, 300, 4000)) - db(band(noise, 300, 4000)),
            highSNR: db(band(speech, 2000, 5000)) - db(band(noise, 2000, 5000)),
            tilt: db(band(speech, 2000, 5000)) - db(band(speech, 300, 1500)),
            speechFraction: Float(speechIdx.count) / Float(vad.count))
    }

    /// Derives parameters from a scene estimate.
    /// - Strength: 15% when the speech-band SNR is >= 21 dB, 80% at <= 8 dB. Classrooms measured around 15 dB -> 45%,
    ///   matching the 50% that gave the fewest dropouts with enough noise reduction in offline comparisons. Capped at 80%: higher gets choppy and loses detail.
    /// - Clarity: fixed emphasis + 70% of the high-frequency deficit relative to normal speech, 0-12 dB; limited when the high-band SNR is low, to avoid boosting hiss.
    /// - agcGainDB: current auto volume gain. It also amplifies the noise left after denoising, so every dB above 10 dB
    ///   adds 1.5% strength (on a device with very quiet capture the gain hit +24 dB and 38% noise reduction could not hold the floor down).
    static func params(for e: Estimate, agcGainDB: Float = 0) -> Params {
        let base = (24 - e.speechSNR) / 20 + max(0, agcGainDB - 10) * 0.015
        let strength = min(0.8, max(0.15, base))
        var clarity = min(12, max(0, baseClarity + (referenceTilt - e.tilt) * 0.7))
        if e.highSNR < 6 { clarity = min(clarity, max(0, e.highSNR)) }
        return Params(strength: strength, clarityDB: clarity)
    }
}
