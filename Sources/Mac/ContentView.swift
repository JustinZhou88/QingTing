import SwiftUI

// The UI follows the look of macOS System Settings: grouped form, small colored icons, explanations under each group.
// The structure mirrors the iPhone version.

struct ContentView: View {
    @EnvironmentObject var audio: AudioController

    var body: some View {
        Form {
            Section { HeroView() }

            if let msg = audio.errorMessage {
                Section {
                    Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }

            Section {
                Picker(selection: $audio.inputUID) {
                    ForEach(audio.inputs) { d in
                        Text(d.looksLikeIPhone ? "\(d.name)（iPhone 麦克风）" : d.name).tag(d.uid)
                    }
                    if audio.selectedInput == nil, !audio.inputUID.isEmpty {
                        Text("设备未连接").tag(audio.inputUID)
                    }
                } label: {
                    SettingsLabel("收音", symbol: "mic.fill", color: .orange)
                }
                Picker(selection: $audio.outputUID) {
                    ForEach(audio.outputs) { d in Text(d.name).tag(d.uid) }
                    if audio.selectedOutput == nil, !audio.outputUID.isEmpty {
                        Text("助听器未连接").tag(audio.outputUID)
                    }
                } label: {
                    SettingsLabel("输出", symbol: "hearingdevice.ear.fill", color: .blue)
                }
            } header: {
                Text("收音与输出")
            } footer: {
                if audio.feedbackRisk {
                    Text("Mac 麦克风加 Mac 扬声器会啸叫，请选助听器或耳机输出。").foregroundStyle(.orange)
                }
            }

            Section {
                Toggle(isOn: $audio.autoTune) {
                    SettingsLabel("自动调参", symbol: "wand.and.stars", color: .purple)
                }
                .disabled(audio.bypass)
                Toggle(isOn: $audio.autoGain) {
                    SettingsLabel("自动音量", symbol: "speaker.wave.2.fill", color: .pink)
                }
                .disabled(audio.bypass)
            } header: {
                Text("自动")
            } footer: {
                Text(autoFooter)
            }

            Section {
                Slider(value: $audio.volumeDB, in: -20...Double(VoiceChain.maxVolumeDB)) {
                    SettingsLabel("音量", symbol: "speaker.fill", color: .gray)
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                Toggle(isOn: $audio.bypass) {
                    SettingsLabel("原声对比", symbol: "waveform", color: .gray)
                }
            } header: {
                Text("声音")
            } footer: {
                Text("打开原声对比会暂时关闭所有处理，用来听听降噪前后的差别。")
            }

            Section {
                Picker(selection: $audio.engine) {
                    ForEach(DenoiseEngine.allCases) { e in
                        Text("\(e.title)（约 \(Int(e.latency * 1000)) 毫秒）").tag(e)
                    }
                } label: {
                    SettingsLabel("降噪引擎", symbol: "cpu", color: .indigo)
                }
                Picker(selection: $audio.mode) {
                    ForEach(ListeningMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    SettingsLabel("场景", symbol: "person.wave.2.fill", color: .teal)
                }
            } header: {
                Text("降噪")
            } footer: {
                Text("\(audio.engine.detail)。\(audio.mode.detail)。")
            }

            Section {
                ValueSlider(title: "降噪强度", value: $audio.strength, range: 0...1,
                            text: "\(Int(audio.strength * 100))%")
                ValueSlider(title: "清晰度", value: $audio.clarityDB, range: 0...Double(VoiceChain.maxClarityDB),
                            text: String(format: "+%.0f dB", audio.clarityDB))
            } header: {
                Text("手动调节")
            } footer: {
                Text(audio.autoTune
                     ? "自动调参开启时由系统调节，这里只显示当前值。"
                     : "降噪太强会一顿一顿、丢细节，一般 40–60% 就够。清晰度强调 s、sh、f 等辅音，发闷就调高，刺耳就调低。")
            }
            .disabled(audio.autoTune || audio.bypass)

            Section {
                LabeledContent {
                    Button("保存", action: audio.saveRecent).disabled(!audio.isRunning)
                } label: {
                    SettingsLabel("最近 30 秒录音", symbol: "square.and.arrow.down", color: .green)
                }
                LabeledContent("延迟", value: audio.isRunning ? String(format: "约 %.0f 毫秒", audio.latencyMs) : "—")
                LabeledContent("自动增益", value: audio.isRunning && audio.autoGain ? String(format: "%+.0f dB", audio.agcGainDB) : "—")
                LabeledContent("卡顿次数", value: audio.isRunning ? "\(audio.glitches)" : "—")
            } header: {
                Text("录音与诊断")
            } footer: {
                Text(audio.savedMessage ?? "老师的声音听不清时保存一段，用来分析和改进。延迟不含蓝牙传输和助听器内部处理。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560, idealHeight: 760)
    }

    private var autoFooter: String {
        guard audio.autoTune else { return "自动调参关闭时，可在下方手动设置降噪强度和清晰度。" }
        if audio.isRunning, let s = audio.sceneSummary { return s }
        return "根据现场声音自动设置降噪强度和清晰度；自动音量会把忽大忽小的人声拉平。"
    }
}

// MARK: - Status header

private struct HeroView: View {
    @EnvironmentObject var audio: AudioController

    var body: some View {
        VStack(spacing: 12) {
            Button(action: audio.toggle) {
                ZStack {
                    Circle()
                        .fill(audio.isRunning ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quaternary))
                        .frame(width: 96, height: 96)
                    Image(systemName: audio.isRunning ? "ear.badge.waveform" : "ear")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(audio.isRunning ? Color.white : Color.accentColor)
                        .symbolEffect(.variableColor.iterative, isActive: audio.isRunning)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(audio.isRunning ? "停止（空格）" : "开始（空格）")

            VStack(spacing: 3) {
                Text(audio.isRunning ? "正在收听" : "点按开始").font(.title3.weight(.semibold))
                Text(audio.isRunning
                     ? String(format: "送往 %@ · 延迟约 %.0f 毫秒", audio.selectedOutput?.name ?? "—", audio.latencyMs)
                     : "连好助听器后开始")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if audio.isRunning {
                VStack(spacing: 6) {
                    WaveformRow(label: "收音", levels: audio.inputWave.values, color: .secondary)
                    WaveformRow(label: "送出", levels: audio.outputWave.values, color: .accentColor)
                }
                .padding(.horizontal, 32)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .animation(.smooth, value: audio.isRunning)
    }
}

// MARK: - Components

/// Row label in the style of System Settings: a white symbol on a colored rounded square
struct SettingsLabel: View {
    let title: String
    let symbol: String
    let color: Color

    init(_ title: String, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let text: String

    var body: some View {
        LabeledContent {
            HStack {
                Slider(value: $value, in: range).labelsHidden()
                Text(text).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }
}

