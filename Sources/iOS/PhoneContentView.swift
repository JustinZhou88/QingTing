import AVKit
import SwiftUI

// The UI follows the look of iOS Settings and Health > Hearing: native grouped list, colored icons, explanations in the footers.
// The home screen only holds the switches used during a class; engine, manual parameters, recording and diagnostics live on a second page.

struct PhoneContentView: View {
    @EnvironmentObject var audio: PhoneController

    var body: some View {
        NavigationStack {
            List {
                Section { HeroView(meters: audio.meters) }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                if let msg = audio.errorMessage {
                    Section {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline)
                    }
                }

                Section {
                    HStack {
                        SettingsLabel("输出", symbol: "hearingdevice.ear.fill", color: .blue)
                        Spacer()
                        Text(audio.outputName)
                            .foregroundStyle(audio.outputIsBuiltIn ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                        RoutePicker().frame(width: 28, height: 28)
                    }
                    // A segmented control for a choice of three: one tap selects, no menu pops up (pop-up menus were hard to use on a real device while running)
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsLabel("麦克风方向", symbol: "iphone.gen3", color: .gray)
                        Picker("麦克风方向", selection: $audio.micPosition) {
                            ForEach(MicPosition.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding(.vertical, 2)
                    Toggle(isOn: directional) {
                        SettingsLabel("指向收音", symbol: "mic.fill", color: .orange)
                    }
                } header: {
                    Text("收音")
                } footer: {
                    Text(routingFooter)
                }

                Section {
                    Toggle(isOn: $audio.autoTune) {
                        SettingsLabel("自动调参", symbol: "wand.and.stars", color: .purple)
                    }
                    Toggle(isOn: $audio.autoGain) {
                        SettingsLabel("自动音量", symbol: "speaker.wave.2.fill", color: .pink)
                    }
                    .disabled(audio.bypass)
                } header: {
                    Text("自动")
                } footer: {
                    AutoFooter(meters: audio.meters)
                }

                Section {
                    Slider(value: $audio.volumeDB, in: -20...Double(VoiceChain.maxVolumeDB)) {
                        Text("音量")
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
                    NavigationLink {
                        AdvancedView()
                    } label: {
                        SettingsLabel("降噪与高级", symbol: "slider.horizontal.3", color: .indigo)
                    }
                }
            }
            .navigationTitle("清听")
        }
    }

    private var directional: Binding<Bool> {
        Binding(get: { audio.micPattern == .cardioid },
                set: { audio.micPattern = $0 ? .cardioid : .omni })
    }

    private var routingFooter: String {
        var parts: [String] = []
        if audio.outputIsBuiltIn { parts.append("还没连上助听器：轻点右侧的图标选择助听器。") }
        parts.append("把手机\(directionPhrase)朝向老师。")
        if audio.directionalUnavailable {
            parts.append("这个方向的麦克风只能全向收音，指向收音没有生效。")
        } else if audio.micPattern == .cardioid {
            parts.append("指向收音只收正对方向的声音：手机没对准老师时声音会变小变闷，延迟也多约 30 毫秒。一般建议关闭。")
        } else {
            parts.append("全向收音，延迟最低。")
        }
        if !audio.micDescription.isEmpty { parts.append("当前：\(audio.micDescription)。") }
        return parts.joined()
    }

    private var directionPhrase: String {
        switch audio.micPosition {
        case .back: "背面"
        case .front: "屏幕"
        case .bottom: "底部"
        }
    }

}

/// Footer of the "Auto" group: shows the scene analysis result while running (updates once a second, so it observes meters on its own)
private struct AutoFooter: View {
    @EnvironmentObject var audio: PhoneController
    @ObservedObject var meters: PhoneMeters

    var body: some View {
        if !audio.autoTune {
            Text("自动调参关闭时，可在「降噪与高级」里手动设置降噪强度和清晰度。")
        } else if audio.isRunning, let s = meters.sceneSummary {
            Text(s)
        } else {
            Text("根据现场声音自动设置降噪强度和清晰度；自动音量会把忽大忽小的人声拉平。")
        }
    }
}

// MARK: - Status header

private struct HeroView: View {
    @EnvironmentObject var audio: PhoneController
    @ObservedObject var meters: PhoneMeters

    var body: some View {
        VStack(spacing: 14) {
            Button(action: audio.toggle) {
                ZStack {
                    Circle()
                        .fill(audio.isRunning ? Color.accentColor.gradient : Color(.secondarySystemGroupedBackground).gradient)
                        .frame(width: 132, height: 132)
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    Image(systemName: audio.isRunning ? "ear.badge.waveform" : "ear")
                        .font(.system(size: 52, weight: .medium))
                        .foregroundStyle(audio.isRunning ? .white : Color.accentColor)
                        .symbolEffect(.variableColor.iterative, isActive: audio.isRunning)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact(weight: .medium), trigger: audio.isRunning)
            .accessibilityLabel(audio.isRunning ? "停止" : "开始")

            VStack(spacing: 4) {
                Text(audio.isRunning ? "正在收听" : "轻点开始")
                    .font(.title2.weight(.semibold))
                Text(audio.isRunning
                     ? String(format: "送往 %@ · 延迟约 %.0f 毫秒", audio.outputName, (meters.latencyMs / 5).rounded() * 5)
                     : "连好助听器后开始，锁屏也会继续")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if audio.isRunning {
                VStack(spacing: 6) {
                    WaveformRow(label: "收音", levels: meters.inputWave.values, color: .secondary)
                    WaveformRow(label: "送出", levels: meters.outputWave.values, color: .accentColor)
                }
                .padding(.horizontal, 28)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .animation(.smooth, value: audio.isRunning)
    }
}

// MARK: - Second-level page

private struct AdvancedView: View {
    @EnvironmentObject var audio: PhoneController

    var body: some View {
        List {
            Section {
                NavigationLink {
                    EnginePicker()
                } label: {
                    LabeledContent {
                        Text(audio.engine.title)
                    } label: {
                        SettingsLabel("降噪引擎", symbol: "cpu", color: .indigo)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SettingsLabel("场景", symbol: "person.wave.2.fill", color: .teal)
                    Picker("场景", selection: $audio.mode) {
                        ForEach(ListeningMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.vertical, 2)
            } header: {
                Text("降噪")
            } footer: {
                Text(audio.mode.detail)
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
                Button(action: audio.saveRecent) {
                    SettingsLabel("保存最近 30 秒", symbol: "square.and.arrow.down", color: .green)
                }
                .disabled(!audio.isRunning)
            } header: {
                Text("录音")
            } footer: {
                Text(audio.savedMessage ?? "老师的声音听不清时保存一段，用来分析和改进。录音只存在这台手机上。")
            }

            Section("诊断") {
                LabeledContent("麦克风", value: audio.micDescription.isEmpty ? "—" : audio.micDescription)
                DiagnosticsRows(meters: audio.meters)
            }
        }
        .navigationTitle("降噪与高级")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Single-choice list in the style of Settings: a checkmark on the selected item, with a description under each
private struct EnginePicker: View {
    @EnvironmentObject var audio: PhoneController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(DenoiseEngine.allCases) { e in
                    Button {
                        audio.engine = e
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(e.title).foregroundStyle(.primary)
                                Text(e.detail).font(.footnote).foregroundStyle(.secondary)
                                Text("延迟约 \(Int(e.latency * 1000)) 毫秒").font(.footnote).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if e == audio.engine {
                                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    // Body text uses the primary color and only the checkmark is tinted (as in Settings)
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("远处的老师建议用 DeepFilterNet。Apple 语音隔离是打电话用的，会把远处的人声也当成背景压掉。")
            }
        }
        .navigationTitle("降噪引擎")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DiagnosticsRows: View {
    @EnvironmentObject var audio: PhoneController
    @ObservedObject var meters: PhoneMeters

    var body: some View {
        LabeledContent("延迟", value: audio.isRunning ? String(format: "约 %.0f 毫秒", (meters.latencyMs / 5).rounded() * 5) : "—")
        LabeledContent("自动增益", value: audio.isRunning && audio.autoGain ? String(format: "%+.0f dB", meters.agcGainDB) : "—")
        LabeledContent("卡顿次数", value: audio.isRunning ? "\(meters.glitches)" : "—")
    }
}

// MARK: - Components

/// Row label in the style of the Settings app: a white symbol on a colored rounded square
private struct SettingsLabel: View {
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title, value: text).monospacedDigit()
            Slider(value: $value, in: range) { Text(title) }
        }
    }
}

/// The system output picker button (hearing aids, headphones...)
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
