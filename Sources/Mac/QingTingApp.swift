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

        // 关掉窗口后也能从菜单栏开关
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

/// 无界面自检：`QingTing --selftest [秒数] [--in 名称片段] [--out 名称片段] [--mode classroom] [--engine deepFilter]`
/// 按秒打印收音/送出电平、缓冲积压、卡顿次数，用来在终端里确认整条链路在跑。
enum SelfTest {
    static func run() {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        let seconds = args.firstIndex(of: "--selftest").flatMap { i in i + 1 < args.count ? Int(args[i + 1]) : nil } ?? 5

        let all = AudioDevices.all()
        print("设备：")
        for d in all {
            print("  [\(d.id)] \(d.name)  in:\(d.inputChannels) out:\(d.outputChannels) \(Int(AudioDevices.sampleRate(d.id)))Hz")
        }
        let inputs = all.filter { $0.inputChannels > 0 }, outputs = all.filter { $0.outputChannels > 0 }
        let input = value(after: "--in").flatMap { q in inputs.first { $0.name.localizedCaseInsensitiveContains(q) } }
            ?? inputs.first { $0.isBuiltIn } ?? inputs.first
        let output = value(after: "--out").flatMap { q in outputs.first { $0.name.localizedCaseInsensitiveContains(q) } }
            ?? outputs.first { $0.looksLikeHearingAid } ?? outputs.first
        guard let input, let output else { print("找不到设备"); exit(1) }
        let mode = value(after: "--mode").flatMap(ListeningMode.init) ?? .classroom
        print("收音：\(input.name) → 输出：\(output.name)  场景：\(mode.title)")

        let pipeline = LivePipeline()
        let engine = value(after: "--engine").flatMap(DenoiseEngine.init) ?? .deepFilter
        pipeline.chain.apply(mode.preset)
        pipeline.chain.setVolume(value(after: "--vol").flatMap(Float.init) ?? 0)
        if args.contains("--bypass") { pipeline.chain.setBypass(true) }
        do {
            try pipeline.start(input: input, output: output, engine: engine, strength: 1)
        } catch {
            print("启动失败：\(error.localizedDescription)")
            exit(1)
        }
        print(String(format: "固定延迟估算 %.1f ms（输入设备 %.1f + 输出设备 %.1f + %@ %.0f）",
                     pipeline.baseLatency * 1000,
                     AudioDevices.latency(input.id, input: true) * 1000,
                     AudioDevices.latency(output.id, input: false) * 1000,
                     engine.title, engine.latency * 1000))
        for s in 1...seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let c = pipeline.consumer!
            print(String(format: "%2ds  收音 %6.1f dBFS  送出 %6.1f dBFS  积压 %5.1f ms  目标 %5.1f ms  欠载 %d  跳帧 %d  每帧 %dµs",
                         s, pipeline.inputMeter.dBFS, pipeline.outputMeter.dBFS, pipeline.bufferedMs,
                         Double(c.targetFill) / c.sampleRate * 1000,
                         c.underruns.load(ordering: .relaxed), c.drops.load(ordering: .relaxed),
                         pipeline.worker?.lastFrameMicros.load(ordering: .relaxed) ?? 0))
        }
        pipeline.stop()
        exit(0)
    }
}
