import SwiftUI
struct AudioPanel: View {
    @ObservedObject var capture: AudioCapture
    let available: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("语音识别", selection: $capture.useDoubao) {
                Text("豆包输入法（MiRemoteV 2ch / 右⌘）").tag(true)
                Text("Apple 本机识别").tag(false)
            }.disabled(capture.armed || capture.recognizing)
            if capture.useDoubao { Text("请在豆包输入法中选择 MiRemoteV 2ch 麦克风，并开启全局唤起语音。识别与文字输入由豆包完成。").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Toggle("按住说话，松开自动输入", isOn: Binding(get: { capture.automatic }, set: { capture.enableAutomatic($0) })).disabled(!available)
                Button("允许输入文字") { capture.requestInputPermission() }
            }
            HStack {
                Button("开始录音验证") { capture.arm() }.disabled(!available || capture.armed || capture.recognizing)
                Button("结束录音") { capture.finish() }.disabled(!capture.armed)
                Button("试听声音") { capture.play() }.disabled(capture.armed || capture.sampleCount == 0 || capture.recognizing)
                Button("转成文字（本机）") { capture.recognize() }.disabled(capture.armed || capture.sampleCount == 0 || capture.recognizing)
            }
            Text(capture.status).font(.callout)
            Text(capture.summary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            ScrollView { Text(capture.transcript.isEmpty ? "识别文字将在这里显示" : capture.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 70)
        }.padding(12).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
