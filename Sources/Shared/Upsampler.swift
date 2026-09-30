import Foundation

/// 整数倍升采样（多相 FIR），逐块处理，可在实时线程用。
/// 有的设备连上助听器后收音只有 16kHz 或 24kHz（iPhone 13 mini 上就是 16kHz），
/// 而 DeepFilterNet / RNNoise 只认 48kHz，所以先升到 48kHz 再降噪。
final class Upsampler {
    let factor: Int
    /// 每相的抽头数；滤波器带来的延迟 = tapsPerPhase/2 个输入样本（16kHz 时约 0.5ms）
    private let tapsPerPhase = 16
    private var phases: [[Float]]
    private var history: [Float]
    private var pos = 0

    /// 支持的整数倍数：48000 / 输入采样率。不是整数倍时返回 nil。
    static func factor(from sampleRate: Double, to target: Double = 48000) -> Int? {
        let f = target / sampleRate
        guard f >= 1, abs(f - f.rounded()) < 1e-6, f <= 8 else { return nil }
        return Int(f.rounded())
    }

    init(factor: Int) {
        self.factor = factor
        let taps = tapsPerPhase
        let n = taps * factor
        // 加汉宁窗的 sinc 低通，截止在输入奈奎斯特频率的 0.9 倍
        var h = [Float](repeating: 0, count: n)
        let center = Double(n - 1) / 2, cutoff = 0.9 / Double(factor)
        for i in 0..<n {
            let x = Double(i) - center
            let sinc = x == 0 ? cutoff : sin(Double.pi * cutoff * x) / (Double.pi * x)
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
            h[i] = Float(sinc * window * Double(factor))
        }
        // 拆成 factor 个相位：第 p 相用 h[p], h[p+factor], ...
        phases = (0..<factor).map { p in (0..<taps).map { h[p + $0 * factor] } }
        history = [Float](repeating: 0, count: taps)
    }

    /// input 的 count 个样本 → output 的 count × factor 个样本。
    func process(_ input: UnsafePointer<Float>, count: Int, into output: UnsafeMutablePointer<Float>) {
        let taps = tapsPerPhase
        history.withUnsafeMutableBufferPointer { hist in
            for i in 0..<count {
                hist[pos] = input[i]
                pos = (pos + 1) % taps
                for p in 0..<factor {
                    var acc: Float = 0
                    // 最新的样本对应抽头 0
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
