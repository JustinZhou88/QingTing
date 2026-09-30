import AVFoundation
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        } else if CommandLine.arguments.contains("--offline") {
            OfflineTool.run()
        } else {
            QingTingApp.main()
        }
    }
}

struct QingTingApp: App {
    @StateObject private var audio = AudioController()

    var body: some Scene {
        Window("清听", id: "main") {
            ContentView().environmentObject(audio)
        }
        .windowResizability(.contentMinSize)

        // Lets the app be switched on and off from the menu bar after the window is closed
        MenuBarExtra("清听", systemImage: audio.isRunning ? "ear.fill" : "ear") {
            Button(audio.isRunning ? "停止" : "开始", action: audio.toggle)
            Picker("场景", selection: $audio.mode) {
                ForEach(ListeningMode.allCases) { Text($0.title).tag($0) }
            }
            Picker("降噪引擎", selection: $audio.engine) {
                ForEach(DenoiseEngine.allCases) { Text($0.title).tag($0) }
            }
            Toggle("自动调参", isOn: $audio.autoTune)
            Toggle("自动音量", isOn: $audio.autoGain)
            Toggle("原声对比", isOn: $audio.bypass)
            Button("保存最近 30 秒录音", action: audio.saveRecent).disabled(!audio.isRunning)
            Divider()
            Button("退出清听") { NSApp.terminate(nil) }
        }
    }
}

/// Headless self-test: `QingTing --selftest [seconds] [--in name] [--out name] [--mode classroom] [--engine deepFilter]`
/// Prints capture/output levels, buffer backlog and glitch counts once a second, to confirm from a terminal that the whole path is running.
enum SelfTest {
    static func run() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        let seconds = args.firstIndex(of: "--selftest").flatMap { i in i + 1 < args.count ? Int(args[i + 1]) : nil } ?? 5

        let all = AudioDevices.all()
        print("Devices:")
        for d in all {
            print("  [\(d.id)] \(d.name)  in:\(d.inputChannels) out:\(d.outputChannels) \(Int(AudioDevices.sampleRate(d.id)))Hz")
        }
        let inputs = all.filter { $0.inputChannels > 0 }, outputs = all.filter { $0.outputChannels > 0 }
        let input = value(after: "--in").flatMap { q in inputs.first { $0.name.localizedCaseInsensitiveContains(q) } }
            ?? inputs.first { $0.isBuiltIn } ?? inputs.first
        let output = value(after: "--out").flatMap { q in outputs.first { $0.name.localizedCaseInsensitiveContains(q) } }
            ?? outputs.first { $0.looksLikeHearingAid } ?? outputs.first
        guard let input, let output else { print("No device found"); exit(1) }
        let mode = value(after: "--mode").flatMap(ListeningMode.init) ?? .classroom
        print("Capture: \(input.name) -> output: \(output.name)  scene: \(mode.rawValue)")

        let pipeline = LivePipeline()
        let engine = value(after: "--engine").flatMap(DenoiseEngine.init) ?? .deepFilter
        pipeline.chain.apply(mode.preset)
        pipeline.chain.setVolume(value(after: "--vol").flatMap(Float.init) ?? 0)
        if args.contains("--bypass") { pipeline.chain.setBypass(true) }
        do {
            try pipeline.start(input: input, output: output, engine: engine, strength: 1)
        } catch {
            print("Failed to start: \(error.localizedDescription)")
            exit(1)
        }
        print(String(format: "Estimated fixed latency %.1f ms (input device %.1f + output device %.1f + %@ %.0f)",
                     pipeline.baseLatency * 1000,
                     AudioDevices.latency(input.id, input: true) * 1000,
                     AudioDevices.latency(output.id, input: false) * 1000,
                     engine.rawValue, engine.latency * 1000))
        for s in 1...seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let c = pipeline.consumer!
            print(String(format: "%2ds  in %6.1f dBFS  out %6.1f dBFS  backlog %5.1f ms  target %5.1f ms  underruns %d  skips %d  frame %d us",
                         s, pipeline.inputMeter.dBFS, pipeline.outputMeter.dBFS, pipeline.bufferedMs,
                         Double(c.targetFill) / c.sampleRate * 1000,
                         c.underruns.load(ordering: .relaxed), c.drops.load(ordering: .relaxed),
                         pipeline.worker?.lastFrameMicros.load(ordering: .relaxed) ?? 0))
        }
        pipeline.stop()
        exit(0)
    }
}
