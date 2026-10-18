import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DiagnosticLogPanel:View {
    @ObservedObject private var log=DiagnosticLog.shared
    @State private var message=""
    var body:some View {
        GlassCard(title:"临时诊断日志") {
            Toggle("记录稳定性诊断日志",isOn:$log.enabled)
            Text("仅记录遥控器会话、麦克风切换、耗时与错误；不保存声音、识别文字或键盘输入。电脑语音由豆包处理，不监听原生快捷键。").font(.caption).foregroundStyle(.secondary)
            Text("最多 4 份，每份 512 KB，总计不超过 2 MB；7 天未更新的日志文件在下次使用日志时清理。日志只保存在本机，不自动上传。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("打开日志目录") {
                    do {try FileManager.default.createDirectory(at:log.directory,withIntermediateDirectories:true);NSWorkspace.shared.open(log.directory)}
                    catch {message="无法打开日志目录"}
                }
                Button("导出日志") {export()}
                Button("清空日志",role:.destructive) {
                    do {try log.clear();message="日志已清空"}
                    catch {message="清空失败，请检查目录权限"}
                }
            }
            if !log.problem.isEmpty {Text(log.problem).font(.caption).foregroundStyle(.orange)}
            if !message.isEmpty {Text(message).font(.caption).foregroundStyle(.secondary)}
            Text("稳定验收后可关闭记录，并在后续版本整体移除这项临时功能。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func export() {
        let panel=NSSavePanel();panel.nameFieldStringValue="小娜迦-诊断日志.jsonl"
        panel.allowedContentTypes=[UTType(filenameExtension:"jsonl") ?? .plainText]
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {try log.contents().write(to:url,options:.atomic);message="日志已导出"}
        catch {message="日志导出失败，请选择可写入的位置"}
    }
}
