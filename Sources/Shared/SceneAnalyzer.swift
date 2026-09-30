import Accelerate
import Foundation

/// 现场声学分析：从最近几秒的原始收音里估计人声频段信噪比、高频衰减，据此给出降噪强度和清晰度。
/// 做法：按 300–3000Hz 能量把帧分成"有人说话""停顿"两类，分别求平均功率谱，
/// 说话谱减去噪声谱就是估计的人声谱。
final class SceneAnalyzer {
    struct Estimate {
        var speechSNR: Float      // 300–4000Hz 人声/噪声（dB）
        var highSNR: Float        // 2–5kHz 人声/噪声（dB）
        var tilt: Float           // 人声 2–5kHz 相对 300–1500Hz（dB），越负越闷
        var speechFraction: Float // 有人说话的帧占比
    }

    struct Params {
        var strength: Float       // 降噪强度 0...1
        var clarityDB: Float      // 2kHz 以上提升
    }

    /// 近距离正常说话时 2–5kHz 相对 300–1500Hz 的电平（dB）。
    /// 长时平均语音谱（Byrne 1994）算得约 -14.3，近讲 TTS 实测 -14.7。
    static let referenceTilt: Float = -14
    /// 不论距离，都给辅音一点固定强调：戴助听器在噪声里分辨辅音本来就吃力
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

    /// 分析一段音频；有效人声太少（没人说话）时返回 nil，调用方应保持原参数。
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

    /// 由现场估计算参数。
    /// - 降噪强度：人声频段信噪比 ≥21dB 只留 15%，≤8dB 用到 80%；课堂实测约 15dB → 45%，
    ///   与离线对比里断续最少、降噪量足够的 50% 一致。上限 80%：再高会一顿一顿、丢细节。
    /// - 清晰度：固定强调 + 高频相对正常语音缺失量的 70%，0–12dB；高频信噪比低时限制，避免放大嘶嘶声。
    /// - agcGainDB：自动音量当前的增益。它把降噪后剩下的底噪也一起放大，超过 10dB 的部分
    ///   每 1dB 多给 1.5% 的降噪强度（真机上收音很小时增益顶到 +24dB，38% 的降噪压不住底噪）。
    static func params(for e: Estimate, agcGainDB: Float = 0) -> Params {
        let base = (24 - e.speechSNR) / 20 + max(0, agcGainDB - 10) * 0.015
        let strength = min(0.8, max(0.15, base))
        var clarity = min(12, max(0, baseClarity + (referenceTilt - e.tilt) * 0.7))
        if e.highSNR < 6 { clarity = min(clarity, max(0, e.highSNR)) }
        return Params(strength: strength, clarityDB: clarity)
    }
}
