import Foundation

/// 4 阶巴特沃斯高通（两个二阶节级联），逐样本处理，可在实时线程用。
/// 收音后、降噪前先切掉空调/通风/桌面震动这类低频：课堂录音里 250Hz 以下的噪声比人声还大，
/// 它会让降噪模型以为整段都很吵而下手过重，连带压掉辅音细节。
final class HighPassFilter {
    private struct Section {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var z1: Float = 0, z2: Float = 0
    }
    private var sections: [Section]

    init(cutoff: Double, sampleRate: Double) {
        // 4 阶巴特沃斯的两个二阶节 Q 值
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
                // 转置直接 II 型
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
