import Accelerate
import AVFoundation

/// Offline comparison: `QingTing --offline recording.wav [--out dir] [--mode classroom] [--strength 1] [--engines deepFilter,rnnoise] [--nochain]`
/// Runs a recording through the same chain as live use (denoiser -> EQ -> Apple isolation -> compressor -> limiter), once per engine,
/// writes a WAV for each to listen to, and prints latency, noise floor reduction and the share of speech that was wiped out.
enum OfflineTool {
    static let sampleRate = 48000.0
    /// Whether auto gain is on during offline rendering (mirrors the "auto volume" switch in the app)
    nonisolated(unsafe) static var autoGain = true

    static func run() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard let path = value(after: "--offline") else { print("usage: --offline recording.wav"); exit(1) }
        let inURL = URL(fileURLWithPath: path)
        let outDir = URL(fileURLWithPath: value(after: "--out") ?? inURL.deletingLastPathComponent().path)
        let mode = value(after: "--mode").flatMap(ListeningMode.init) ?? .classroom
        let strength = value(after: "--strength").flatMap(Float.init) ?? 1
        let engines = value(after: "--engines")?.split(separator: ",").compactMap { DenoiseEngine(rawValue: String($0)) }
            ?? DenoiseEngine.allCases
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        do {
            let input = try readMono48k(inURL)
            print(String(format: "Input %.1f s, scene %@, strength %.0f%%", Double(input.count) / sampleRate, mode.rawValue, strength * 100))
            print("engine            latency   floor reduction   speech level   speech wiped   realtime")
            let inStats = levelStats(input)
            for engine in engines {
                let t0 = Date()
                let denoised = try denoise(input, engine: engine, strength: strength)
                // --nochain: look at the denoiser alone (for latency measurement). The Apple engines live in the chain, so they are still rendered
                let out = args.contains("--nochain") && engine.isFrameBased
                    ? denoised : try renderChain(denoised, engine: engine, mode: mode, strength: strength)
                let speed = Double(input.count) / sampleRate / Date().timeIntervalSince(t0)
                let lag = estimateLag(reference: input, signal: out)
                let aligned = Array(out.dropFirst(lag)) + [Float](repeating: 0, count: lag)
                let s = levelStats(aligned)
                let erased = erasedFraction(input: input, output: aligned, noiseFloor: inStats.floor)
                let name = "\(inURL.deletingPathExtension().lastPathComponent)_\(engine.rawValue).wav"
                try write(out, to: outDir.appendingPathComponent(name))
                print(String(format: "%@  %5.0f ms        %6.1f dB    %6.1f dBFS        %5.1f%%     %5.0fx",
                             engine.rawValue.padding(toLength: 14, withPad: " ", startingAt: 0),
                             Double(lag) / sampleRate * 1000,
                             (s.speech - s.floor) - (inStats.speech - inStats.floor),
                             s.speech, erased * 100, speed))
            }
            print("Output folder: \(outDir.path)")
            print("floor reduction = how much larger the speech-to-floor level gap is than in the input; speech wiped = share of 100 ms windows that had sound in the input but ended up more than 25 dB lower after processing.")
        } catch {
            print("Failed: \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }

    // MARK: - Processing

    /// Same as the live path: low cut first, then frame-based denoising (Apple engines and "off" only get the low cut).
    static func denoise(_ input: [Float], engine: DenoiseEngine, strength: Float) throws -> [Float] {
        let x = HighPassFilter(cutoff: VoiceChain.lowCutHz, sampleRate: sampleRate).processed(input)
        guard let d = try engine.makeDenoiser() else { return x }
        d.setStrength(strength)
        let n = d.frameSize
        var out = [Float](repeating: 0, count: x.count)
        var inBuf = [Float](repeating: 0, count: n), outBuf = [Float](repeating: 0, count: n)
        var i = 0
        while i + n <= x.count {
            for k in 0..<n { inBuf[k] = x[i + k] }
            inBuf.withUnsafeMutableBufferPointer { a in
                outBuf.withUnsafeMutableBufferPointer { b in d.process(a.baseAddress!, b.baseAddress!) }
            }
            for k in 0..<n { out[i + k] = outBuf[k] }
            i += n
        }
        return out
    }

    static func renderChain(_ x: [Float], engine: DenoiseEngine, mode: ListeningMode, strength: Float) throws -> [Float] {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let eng = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let chain = VoiceChain()
        chain.apply(mode.preset)
        chain.setEngine(engine)
        chain.setStrength(strength)
        chain.setVolume(0)
        chain.setAutoGain(autoGain)
        eng.attach(player)
        chain.attach(to: eng)
        chain.connect(in: eng, from: player, to: eng.mainMixerNode, format: format)
        try eng.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        try eng.start()
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(x.count))!
        buf.frameLength = buf.frameCapacity
        x.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        player.scheduleBuffer(buf)
        player.play()
        let ob = AVAudioPCMBuffer(pcmFormat: eng.manualRenderingFormat, frameCapacity: 1024)!
        var out = [Float]()
        out.reserveCapacity(x.count)
        while out.count < x.count {
            _ = try eng.renderOffline(1024, to: ob)
            out += UnsafeBufferPointer(start: ob.floatChannelData![0], count: Int(ob.frameLength))
        }
        eng.stop()
        return Array(out.prefix(x.count))
    }

    // MARK: - Metrics

    /// 10th percentile (noise floor) and 90th percentile (speech) of 100 ms window levels.
    static func levelStats(_ x: [Float]) -> (floor: Float, speech: Float) {
        let w = windowLevels(x).sorted()
        guard !w.isEmpty else { return (-120, -120) }
        return (w[w.count / 10], w[w.count * 9 / 10])
    }

    static func windowLevels(_ x: [Float]) -> [Float] {
        let n = Int(sampleRate / 10)
        return stride(from: 0, to: x.count - n, by: n).map { i in
            var r: Float = 0
            x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + i, 1, &r, vDSP_Length(n)) }
            return 20 * log10(max(r, 1e-7))
        }
    }

    /// Among input windows clearly above the noise floor (mostly speech), the share pushed down by more than 25 dB after processing.
    static func erasedFraction(input: [Float], output: [Float], noiseFloor: Float) -> Double {
        let a = windowLevels(input), b = windowLevels(output)
        let active = a.indices.filter { a[$0] > noiseFloor + 10 }
        guard !active.isEmpty else { return 0 }
        // The output may have been shifted overall by compression or gain, so align levels by the median difference over speech windows
        let diffs = active.map { b[$0] - a[$0] }.sorted()
        let offset = diffs[diffs.count / 2]
        return Double(active.filter { b[$0] - a[$0] - offset < -25 }.count) / Double(active.count)
    }

    /// Delay of the output relative to the input in samples, found as the cross-correlation peak within 0...200 ms.
    static func estimateLag(reference: [Float], signal: [Float]) -> Int {
        let maxLag = Int(sampleRate * 0.2), step = 8
        let n = min(reference.count, signal.count) - maxLag
        guard n > 0 else { return 0 }
        var best = 0, bestC: Float = -.infinity
        for lag in stride(from: 0, through: maxLag, by: step) {
            var c: Float = 0
            reference.withUnsafeBufferPointer { r in
                signal.withUnsafeBufferPointer { s in vDSP_dotpr(r.baseAddress!, 1, s.baseAddress! + lag, 1, &c, vDSP_Length(n)) }
            }
            if c > bestC { bestC = c; best = lag }
        }
        return best
    }

    // MARK: - Files

    static func readMono48k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: src)
        if file.processingFormat.sampleRate == sampleRate, file.processingFormat.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: src.floatChannelData![0], count: Int(src.frameLength)))
        }
        let conv = AVAudioConverter(from: file.processingFormat, to: target)!
        let ratio = sampleRate / file.processingFormat.sampleRate
        let dst = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(src.frameLength) * ratio) + 1024)!
        var fed = false
        var err: NSError?
        conv.convert(to: dst, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        if let err { throw err }
        return Array(UnsafeBufferPointer(start: dst.floatChannelData![0], count: Int(dst.frameLength)))
    }

    static func write(_ x: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(x.count))!
        buf.frameLength = buf.frameCapacity
        x.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buf)
        file.close()
    }
}
