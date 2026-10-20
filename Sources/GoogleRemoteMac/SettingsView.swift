import SwiftUI
import Speech
import AVFoundation
import CoreGraphics
@preconcurrency import ApplicationServices

struct NagaSettingsView:View{
    @ObservedObject var probe:RemoteProbe
    @ObservedObject var capture:AudioCapture
    @ObservedObject var prefs=Preferences.shared
    @ObservedObject private var startup=LoginStartup.shared
    @State private var page="概览"
    @State private var inputs:[AudioEndpoint]=[]
    @State private var outputs:[AudioEndpoint]=[]
    @State private var checkToken=0
    @ObservedObject private var mappings:MappingStore
    init(probe:RemoteProbe,capture:AudioCapture){self.probe=probe;self.capture=capture;self.mappings=probe.mappings}
    @State private var buttonName="上"
    private let pages:[(String,String)]=[("概览","waveform"),("语音与音频","mic"),("遥控器按键","appletvremote.gen4"),("映射方案","square.stack"),("常用词","text.book.closed"),("检查与诊断","checkmark.shield")]
    var body:some View{
        NavigationSplitView{
            VStack(alignment:.leading,spacing:22){
                HStack(spacing:12){Image(systemName:"water.waves").font(.title).foregroundStyle(.teal);VStack(alignment:.leading){Text("小娜迦").font(.title3.bold());Text("Naga Siren").font(.caption).foregroundStyle(.secondary)}}.padding(.horizontal,16).padding(.top,22)
                List(pages,id:\.0,selection:$page){item in Label(item.0,systemImage:item.1).tag(item.0)}.listStyle(.sidebar).scrollContentBackground(.hidden)
                Label("本机 · Chromecast",systemImage:"laptopcomputer").font(.caption).foregroundStyle(.secondary).padding(16)
            }.navigationSplitViewColumnWidth(min:185,ideal:210,max:240)
        }detail:{
            Group {
                if page=="遥控器按键" {
                    VStack(alignment:.leading,spacing:20){pageHeader;buttons}
                        .padding(26).frame(maxWidth:1200,maxHeight:.infinity,alignment:.topLeading)
                } else {
                    ScrollView {
                        VStack(alignment:.leading,spacing:20){pageHeader;content}
                            .padding(30).frame(maxWidth:1050,alignment:.leading)
                    }
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)

        }.tint(.teal).frame(minWidth:1120,minHeight:740)
        .background {WindowGlass().ignoresSafeArea()}
        .modifier(TransparentWindowContent())
        .toolbarBackground(.hidden,for:.windowToolbar)
        .task{
            refresh()
            if !UserDefaults.standard.bool(forKey:"naga.setupCompleted") {page="检查与诊断"}
        }
    }
    private var pageHeader:some View {
        HStack{
            VStack(alignment:.leading,spacing:5){Text(page).font(.largeTitle.bold());Text(subtitle).font(.callout).foregroundStyle(.secondary)}
            Spacer();Circle().fill(probe.voiceReady ? Color.teal:Color.orange).frame(width:8,height:8)
            Text(probe.voiceReady ? "遥控器已连接":"等待遥控器").font(.caption)
        }
    }
    private var subtitle:String{
        switch page{case "概览":return "你的声音，由你掌控";case "语音与音频":return "电脑麦克风与遥控器，自动选源";case "遥控器按键":return "单击、双击与长按";case "映射方案":return "为不同场景保存一套操作";case "常用词":return "让本机备用识别更懂你的表达";default:return "检查权限、连接与音频通道"}
    }
    @ViewBuilder private var content:some View{
        switch page{
        case "概览": overview
        case "语音与音频": audio
        case "遥控器按键": buttons
        case "映射方案": schemes
        case "常用词": words
        default: checks
        }
    }
    private var overview:some View{
        VStack(spacing:20){
            GlassCard(title:"语音控制"){
                HStack{Image(systemName:capture.armed || capture.computer.active ? "waveform.circle.fill":"mic.circle").font(.system(size:48)).foregroundStyle(.teal);VStack(alignment:.leading,spacing:6){Text(capture.computer.active ? "电脑麦克风":capture.sourceName).font(.title2.weight(.semibold));Text(capture.status).font(.callout).foregroundStyle(.secondary)};Spacer()}
                Toggle("启用自动语音输入",isOn:Binding(get:{capture.routeControl.wantsEnabled},set:{capture.enableAutomatic($0)})).disabled(capture.routeChanging)
                HStack{if capture.routeChanging{ProgressView().controlSize(.small)};Text(capture.routeStatus).font(.caption).foregroundStyle(.secondary)}
                HStack{Button(capture.routeControl.wantsEnabled ? "暂停语音":"恢复语音"){capture.enableAutomatic(!capture.routeControl.wantsEnabled)}.disabled(capture.routeChanging);Button("紧急停止",role:.destructive){capture.emergencyStop()};Spacer();Button("检查设置"){page="检查与诊断"}}
            }
            GlassCard(title:"日常启动"){
                Toggle("登录后自动启动",isOn:Binding(get:{startup.enabled},set:{startup.setEnabled($0)}))
                Text(startup.message).font(.caption).foregroundStyle(.secondary)
                Text("启动时确认电脑麦克风并自动连接遥控器。关闭设置窗口不影响菜单栏运行。").font(.caption).foregroundStyle(.secondary)
            }
            GlassCard(title:"连接"){
                Text(probe.status).font(.callout)
                HStack{Button("连接上次遥控器"){probe.resume()};Button("扫描设备"){probe.scan()}.disabled(probe.connected);Button("断开"){probe.stop()}}
                ForEach(probe.devices,id:\.identifier){device in HStack{Label(device.name ?? "Chromecast Remote",systemImage:"appletvremote.gen4");Spacer();Button(probe.connected ? "已连接":"连接"){probe.connect(device)}.disabled(probe.connected)}}
            }
            GlassCard(title:"外观与反馈"){
                Label("仅在菜单栏运行；关闭窗口后继续工作",systemImage:"menubar.rectangle")
                Toggle("显示录音浮条",isOn:$prefs.showHUD)
                Toggle("开始与结束提示音",isOn:$prefs.sounds)
                HStack{Text("提示音量");Slider(value:$prefs.volume,in:0...1);Button("试听开始"){Feedback.shared.sound(start:true,preview:true)};Button("试听结束"){Feedback.shared.sound(start:false,preview:true)}}
                Text("提示音从系统播放设备输出；识别通道不混入提示音。使用电脑扬声器时仍可能被实体麦克风拾取，建议使用耳机。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var audio:some View{
        VStack(spacing:20){
            GlassCard(title:"识别与触发"){
                Picker("识别程序",selection:$capture.useDoubao){Text("豆包输入法 · 原生流式输出").tag(true);Text("Apple 本机 · 备用").tag(false)}.disabled(capture.routeChanging || capture.armed || capture.computer.active || capture.computer.draining)
                Text("电脑语音直接由豆包控制，右 Command 和右 Option 保持豆包原生行为。下方按住说话快捷键须与豆包一致，用于遥控器触发。").font(.caption).foregroundStyle(.secondary)
                HStack{Text("按住说话");Spacer();ShortcutRecorder(shortcut:$prefs.holdShortcut).frame(width:240,height:28)}
                HStack{Text("开关型语音");Spacer();ShortcutRecorder(shortcut:$prefs.toggleShortcut).frame(width:240,height:28)}
                if prefs.shortcutsConflict {Text("按住说话与开关型快捷键不能相同").font(.caption).foregroundStyle(.orange)}
                Picker("遥控器模式",selection:$prefs.recordingMode){Text("按住说话").tag("hold");Text("按一次开始，再按一次结束").tag("toggle")}.disabled(capture.armed)
                Picker("最长录音",selection:$prefs.maximumSeconds){ForEach([60,120,180,300,600],id:\.self){Text("\($0/60) 分钟").tag($0)}}.disabled(capture.armed)
            }.disabled(capture.routeChanging || capture.armed || capture.computer.active || capture.computer.draining || capture.recognizing)
            GlassCard(title:"自动切换音源"){
                Text("平时 → 豆包直接使用内置麦克风\n遥控器录音 → 临时切到 MiRemoteV 2ch\n遥控器结束、暂停或退出 → 恢复内置麦克风").font(.callout).lineSpacing(7)
                Picker("电脑麦克风",selection:$prefs.microphoneUID){Text("自动选择内建麦克风").tag("");ForEach(inputs.filter{$0.name != "MiRemoteV 2ch"},id:\.uid){Text($0.name).tag($0.uid)}}
                Picker("虚拟音频输出",selection:$prefs.outputUID){Text("MiRemoteV 2ch（默认）").tag("");ForEach(outputs,id:\.uid){Text($0.name).tag($0.uid)}}
                Text("遥控器开头音频会在切换期间暂存，切换确认后交给豆包。请先结束当前电脑语音，再使用遥控器；两种方式交替使用。请勿选择扬声器输出。").font(.caption).foregroundStyle(.secondary)
                Button("刷新音频设备"){refresh()}
            }.disabled(capture.routeChanging || capture.armed || capture.computer.active || capture.computer.draining || capture.recognizing)
            GlassCard(title:"音量与试听"){
                MicrophoneMeter(computer:capture.computer,capture:capture)
                ComputerRouteStats(computer:capture.computer)
                Text(capture.summary).font(.caption).foregroundStyle(.secondary)
                HStack{Button(capture.computer.active ? "停止电脑麦克风测试":"测试电脑麦克风"){if capture.computer.active{capture.computer.stop()}else{capture.computer.start(force:true)}}.disabled(capture.routeChanging || capture.armed || capture.computer.draining || capture.recognizing);Button("试听电脑麦克风"){capture.computer.playPreview()}.disabled(capture.computer.active || !capture.computer.previewAvailable);Text("测试录音仅在内存保留，最多 30 秒。").font(.caption).foregroundStyle(.secondary)}
                HStack{Button("录一段遥控器声音"){capture.arm()}.disabled(capture.routeChanging || !probe.voiceReady || capture.armed || capture.computer.active || capture.computer.draining || capture.recognizing);Button("结束"){capture.finish()}.disabled(!capture.armed);Button("试听"){capture.play()}.disabled(capture.armed || capture.sampleCount==0)}
                Text("试听录音仅保存在内存，重新开始或退出后清空。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var words:some View{
        GlassCard(title:"常用词"){
            Text("每行一个词。用于 Apple 本机备用识别；豆包的词库仍在豆包内管理，不会偷偷修改其私有数据。").font(.callout).foregroundStyle(.secondary)
            TextEditor(text:$prefs.commonWords).font(.body).frame(height:250).scrollContentBackground(.hidden).padding(10).clipShape(RoundedRectangle(cornerRadius:12))
            HStack{Button("导入词表"){let panel=NSOpenPanel();if panel.runModal() == .OK,let url=panel.url,let text=try? String(contentsOf:url,encoding:.utf8),text.utf8.count<100000{prefs.commonWords=text}};Button("导出词表"){let panel=NSSavePanel();panel.nameFieldStringValue="小娜迦-常用词.txt";if panel.runModal() == .OK,let url=panel.url{try? prefs.commonWords.write(to:url,atomically:true,encoding:.utf8)}};Spacer();Button("清空最近识别"){capture.transcript=""}}
            if !capture.transcript.isEmpty{Text("最近一次 Apple 识别（仅内存）").font(.caption);Text(capture.transcript).textSelection(.enabled)}
        }
    }
    private var checks:some View{
        VStack(spacing:20){
            GlassCard(title:"设置检查"){
                checkRow("辅助功能",ok:AXIsProcessTrusted(),hint:"用于触发豆包快捷键和执行映射"){capture.requestInputPermission()}
                checkRow("麦克风访问",ok:AVCaptureDevice.authorizationStatus(for:.audio) == .authorized,hint:"仅手动麦克风测试时采集；电脑语音由豆包负责"){capture.requestMicrophone()}
                checkRow("输入监控（按键映射）",ok:CGPreflightListenEventAccess(),hint:"用于遥控器按键映射；豆包原生语音不依赖小娜迦监听"){capture.requestMonitoring()}
                checkRow("Apple 语音识别（备用）",ok:SFSpeechRecognizer.authorizationStatus() == .authorized,hint:"豆包模式不依赖此权限"){capture.requestSpeech()}
                checkRow("遥控器语音",ok:probe.voiceReady,hint:probe.status){probe.resume()}
                checkRow("虚拟音频设备",ok:(try? DoubaoBridge.device()) != nil,hint:"豆包麦克风须与所选通道对应"){refresh()}
                Text("电脑右 Command / 右 Option 由豆包直接处理，小娜迦不接管电脑语音快捷键。").font(.caption).foregroundStyle(.secondary)
                ComputerSessionNote(computer:capture.computer)
                HStack{
                    Button("重新检查"){refresh()}
                    Spacer()
                    Button("完成首次设置") {UserDefaults.standard.set(true,forKey:"naga.setupCompleted");page="概览"}
                        .disabled(!AXIsProcessTrusted() || AVCaptureDevice.authorizationStatus(for:.audio) != .authorized || !CGPreflightListenEventAccess() || (try? DoubaoBridge.device()) == nil)
                }
                Text("小娜迦会自动管理豆包麦克风，平时保持内置麦克风。Apple 备用识别权限可稍后开启。").font(.caption).foregroundStyle(.secondary)
            }.id(checkToken)
            DiagnosticLogPanel()
            GlassCard(title:"诊断事件"){
                Text("只记录连接和状态，不记录音频或识别全文。").font(.caption).foregroundStyle(.secondary)
                Text(probe.events.suffix(35).joined(separator:"\n")).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
            }
        }
    }
    private func checkRow(_ title:String,ok:Bool,hint:String,action:@escaping()->Void)->some View{
        HStack{Image(systemName:ok ? "checkmark.circle.fill":"exclamationmark.circle").foregroundStyle(ok ? Color.teal:Color.orange);VStack(alignment:.leading){Text(title);Text(hint).font(.caption).foregroundStyle(.secondary)};Spacer();if !ok{Button("处理",action:action)}}.padding(.vertical,5)
    }
    private var buttons:some View{RemoteButtonPage(store:mappings,capture:capture,receiver:probe.buttons)}
    private var schemes:some View{
        GlassCard(title:"映射方案"){
            Picker("正在使用",selection:$mappings.selected){ForEach(mappings.schemes){Text($0.name).tag($0.id)}}.onChange(of:mappings.selected){_,_ in mappings.save()}
            TextField("方案名称",text:$mappings.schemes[mappings.current].name).textFieldStyle(.roundedBorder)
            HStack{Button("新建空白方案"){let scheme=MappingScheme(name:"新方案",buttons:mappings.ids.map{ButtonMapping(id:$0)});mappings.schemes.append(scheme);mappings.selected=scheme.id;mappings.save()};Button("复制"){mappings.duplicate()};Button("保存名称"){mappings.save()};Button("删除",role:.destructive){mappings.remove()}.disabled(mappings.schemes.count<2)}
            HStack{Button("导入方案"){mappings.importFile()};Button("导出当前方案"){mappings.export()}}
            Text(mappings.status).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func refresh(){inputs=AudioCatalog.devices(input:true);outputs=AudioCatalog.devices(input:false);startup.refresh();checkToken += 1}
}
struct MicrophoneMeter:View{
    @ObservedObject var computer:ComputerVoice
    @ObservedObject var capture:AudioCapture
    var body:some View{HStack{Image(systemName:"waveform").foregroundStyle(.teal);ProgressView(value:Double(computer.active ? computer.level:capture.level)).tint(.teal);Text(computer.active ? "电脑":"遥控器").font(.caption).foregroundStyle(.secondary)}}
}
struct NagaMenu:View{
    @ObservedObject var probe:RemoteProbe
    @ObservedObject var capture:AudioCapture
    @Environment(\.openWindow) private var openWindow
    var body:some View{
        VStack(alignment:.leading,spacing:16){
            HStack{Image(systemName:"water.waves").font(.title2).foregroundStyle(.teal);VStack(alignment:.leading){Text("小娜迦").font(.headline);Text(probe.voiceReady ? "遥控器已就绪":"电脑语音可独立使用").font(.caption).foregroundStyle(.secondary)};Spacer();Circle().fill(capture.automatic ? Color.teal:Color.orange).frame(width:8,height:8)}
            Text(capture.status).font(.callout).fixedSize(horizontal:false,vertical:true)
            HStack{if capture.routeChanging{ProgressView().controlSize(.small)};Text(capture.routeStatus).font(.caption).foregroundStyle(.secondary)}
            MicrophoneMeter(computer:capture.computer,capture:capture)
            Text(capture.computer.active ? "正在采集电脑声音" : (capture.armed ? "正在采集遥控器声音":"当前未采集声音")).font(.caption).foregroundStyle(.secondary)
            HStack{Button(capture.routeControl.wantsEnabled ? "暂停语音":"恢复语音"){capture.enableAutomatic(!capture.routeControl.wantsEnabled)}.disabled(capture.routeChanging);Button("停止",role:.destructive){capture.emergencyStop()}}
            Divider()
            HStack{Button("打开设置…"){openWindow(id:"main");SettingsWindowPresenter.requestOpen()};Spacer();Button("退出小娜迦"){NSApplication.shared.terminate(nil)}}.font(.callout)
        }.padding(20).frame(width:320).background(.regularMaterial)
    }
}

struct ComputerRouteStats:View{
    @ObservedObject var computer:ComputerVoice
    var body:some View{
        VStack(alignment:.leading,spacing:4){
            Text("电脑采集：\(computer.inputFrames) 样本 · 已转发：\(computer.forwardedFrames) 样本").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if !computer.routeError.isEmpty{Text(computer.routeError).font(.caption).foregroundStyle(.orange)}
        }
    }
}

private struct VoiceKeyDiagnostics:View {
    @ObservedObject var keys:VoiceKeyMonitor
    var body:some View {
        VStack(alignment:.leading,spacing:5) {
            Text("语音键诊断（仅配置的快捷键）").font(.caption.bold())
            Text(keys.diagnostics.isEmpty ? "尚未收到语音键事件":keys.diagnostics.joined(separator:"\n"))
                .font(.system(.caption,design:.monospaced)).textSelection(.enabled)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

private struct ComputerSessionNote:View {
    @ObservedObject var computer:ComputerVoice
    var body:some View {Text(computer.lastSession).font(.caption).textSelection(.enabled)}
}
