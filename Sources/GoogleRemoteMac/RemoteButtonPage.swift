import SwiftUI

struct RemoteButtonPage:View {
    @ObservedObject var store:MappingStore
    @ObservedObject var capture:AudioCapture
    @ObservedObject private var prefs=Preferences.shared
    let receiver:RemoteButtons
    @State private var selected="确定"
    @State private var display="按键配置"
    @State private var saved=false
    @State private var resumeAfterDetection=false
    @State private var resumeMappings=false
    @State private var detectionTransition=false
    @State private var detectionTask:Task<Void,Never>?
    @State private var confirmDefaults=false
    private let gestures=["单击","双击","长按"]
    private let names=["上","下","左","右","确定","返回","首页","语音","音量加","音量减","静音","YouTube","Netflix","电源","输入源"]
    var body:some View {
        VStack(spacing:18) {
            toolbar
            HStack(alignment:.top,spacing:22) {
                remotePanel.frame(width:220)
                Group {
                    if display=="全部映射" { mappingTable }
                    else { selectedEditor }
                }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            }.frame(maxHeight:.infinity)
            footer
        }
        .onChange(of:store.lastButton){_,name in if names.contains(name){selected=name}}
        .onChange(of:store.selected){_,_ in store.save();saved=false}
        .onDisappear{if store.detecting || detectionTransition {stopDetection()}}
        .confirmationDialog("恢复当前方案的内置默认映射？",isPresented:$confirmDefaults){
            Button("恢复内置默认",role:.destructive){store.resetDefaults();saved=true}
            Button("取消",role:.cancel){}
        }message:{Text("将替换当前方案中所有按键的单击、双击和长按配置。")}
    }
    private var toolbar:some View {
        HStack(spacing:14) {
            Label("Chromecast Remote",systemImage:"appletvremote.gen4").font(.callout.weight(.semibold))
            Spacer(minLength:8)
            Picker("映射方案",selection:$store.selected){ForEach(store.schemes){Text($0.name).tag($0.id)}}
                .labelsHidden().frame(width:160).accessibilityLabel("当前映射方案")
            Divider().frame(height:22)
            Picker("配置视图",selection:$display){Text("按键配置").tag("按键配置");Text("全部映射").tag("全部映射")}
                .pickerStyle(.segmented).frame(width:200)
        }.padding(14).modifier(RemoteGlassSurface(radius:18))
    }
    private var remotePanel:some View {
        VStack(spacing:10) {
            HStack{Text("选择按键").font(.caption.weight(.medium)).foregroundStyle(.secondary);Spacer();
                if store.detecting {Label("检测中",systemImage:"dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.teal)}
            }.padding(.horizontal,18).padding(.top,18)
            GeometryReader { geometry in
                let scale=max(0,min(1,min((geometry.size.height-4)/540,(geometry.size.width-12)/200)))
                GoogleRemoteLineArt(selected:$selected)
                    .scaleEffect(scale).frame(width:200*scale,height:540*scale)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            Text(store.detecting ? store.lastUsage:selected)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.bottom,16)
        }.frame(maxHeight:.infinity).modifier(RemoteGlassSurface(radius:24))
    }
    private var selectedEditor:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:7){
                        Text(selected+"键").font(.system(size:25,weight:.semibold))
                        Text(selected=="语音" ? "专用于语音输入，独立设置触发方式。":"为不同操作分配动作，修改后自动保存。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName:selected=="语音" ? "mic":"cursorarrow.click")
                        .font(.title2.weight(.light)).foregroundStyle(.teal).padding(12)
                }
                if selected=="语音" {voiceEditor}
                else {
                    VStack(spacing:0){
                        ForEach(gestures,id:\.self){gesture in
                            gestureEditor(gesture)
                            if gesture != "长按" {Divider().padding(.horizontal,18)}
                        }
                    }.clipShape(RoundedRectangle(cornerRadius:18))
                        .overlay(RoundedRectangle(cornerRadius:18).stroke(.primary.opacity(0.06)))
                    Label("字母快捷键会经过当前输入法；测试单个字母请切到英文。",systemImage:"info.circle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                HStack(spacing:6){Image(systemName:"checkmark.circle.fill").foregroundStyle(.teal);Text(saved ? "已保存到“\(store.schemes[store.current].name)”":"当前方案：\(store.schemes[store.current].name)").foregroundStyle(.secondary)}.font(.caption)
            }.padding(22)
        }.modifier(RemoteGlassSurface(radius:24))
    }
    private func gestureEditor(_ gesture:String)->some View {
        let binding=actionBinding(selected,gesture)
        return VStack(alignment:.leading,spacing:12) {
            HStack {
                VStack(alignment:.leading,spacing:5){Text(gesture).font(.callout.weight(.semibold));Text(gestureHint(gesture)).font(.caption).foregroundStyle(.secondary)}
                Spacer(minLength:16)
                Picker("\(selected)·\(gesture)·动作",selection:Binding(get:{binding.wrappedValue.kind},set:{var a=binding.wrappedValue;a.kind=$0;binding.wrappedValue=a})) {
                    actionOptions
                }.labelsHidden().frame(width:180).accessibilityLabel("\(selected)·\(gesture)·动作")
            }
            if binding.wrappedValue.kind=="shortcut" {
                HStack(spacing:8) {
                    Image(systemName:"keyboard").foregroundStyle(.secondary)
                    ShortcutRecorder(shortcut:Binding(get:{binding.wrappedValue.shortcut},set:{var a=binding.wrappedValue;a.shortcut=$0;binding.wrappedValue=a}),allowModifierOnly:false)
                        .frame(height:27).id(selected+gesture+store.selected.uuidString)
                    Menu {ForEach([VoiceShortcut(keyCode:36,modifiers:0,label:"回车"),VoiceShortcut(keyCode:49,modifiers:0,label:"空格"),VoiceShortcut(keyCode:53,modifiers:0,label:"Esc")],id:\.keyCode){key in
                        Button(key.label){var a=binding.wrappedValue;a.shortcut=key;binding.wrappedValue=a}
                    }}label:{Image(systemName:"ellipsis")}.menuStyle(.borderlessButton).frame(width:28).help("常用按键")
                }.padding(10).clipShape(RoundedRectangle(cornerRadius:10))
            }
        }.padding(18)
    }
    @ViewBuilder private var actionOptions:some View {
        Text("未设置 / 不执行").tag("none");Text("键盘快捷键").tag("shortcut");Text("鼠标左键点击").tag("click")
        Text("增大音量").tag("volumeUp");Text("减小音量").tag("volumeDown");Text("切换静音").tag("mute");Text("暂停语音").tag("pauseVoice")
    }
    private var voiceEditor:some View {
        VStack(alignment:.leading,spacing:16){
            Text("遥控器语音模式").font(.headline)
            Picker("遥控器语音模式",selection:$prefs.recordingMode){Text("按住说话，松开结束").tag("hold");Text("按一次开始，再按一次结束").tag("toggle")}.pickerStyle(.radioGroup)
                .disabled(capture.armed || capture.routeChanging)
            Text(prefs.recordingMode=="hold" ? "按住遥控器语音键说话，松开后结束。":"短按语音键即可持续说话，再短按一次结束。")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Label("语音键保留给语音输入，不执行普通按键映射。",systemImage:"mic.badge.plus").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading).clipShape(RoundedRectangle(cornerRadius:18))
    }
    private var rows:[ButtonMapping] {names.map{name in store.schemes[store.current].buttons.first(where:{$0.id==name}) ?? ButtonMapping(id:name)}}
    private var mappingTable:some View {
        VStack(alignment:.leading,spacing:14){
            HStack{Text("全部映射").font(.title2.weight(.semibold));Spacer();Text("点击动作，进入配置").font(.caption).foregroundStyle(.secondary)}.padding(.horizontal,20).padding(.top,20)
            Table(rows,selection:Binding<String?>(get:{selected},set:{if let value=$0{selected=value}})) {
                TableColumn("按键"){row in Text(row.id).fontWeight(selected==row.id ? .semibold:.regular)}.width(min:65,ideal:80,max:110)
                TableColumn("单击"){row in tableAction(row.id,"单击")}.width(min:90,ideal:125)
                TableColumn("双击"){row in tableAction(row.id,"双击")}.width(min:90,ideal:125)
                TableColumn("长按"){row in tableAction(row.id,"长按")}.width(min:90,ideal:125)
            }.tableStyle(.inset(alternatesRowBackgrounds:false)).scrollContentBackground(.hidden)
            Text("未设置的手势不执行动作；语音键使用独立语音模式。").font(.caption).foregroundStyle(.secondary).padding(.horizontal,20).padding(.bottom,16)
        }.modifier(RemoteGlassSurface(radius:24))
    }
    private func tableAction(_ name:String,_ gesture:String)->some View {
        Button{selected=name;display="按键配置"}label:{
            Text(name=="语音" ? (gesture=="单击" ? "语音模式":"专用") : actionBinding(name,gesture).wrappedValue.displayName)
                .foregroundStyle(name != "语音" && actionBinding(name,gesture).wrappedValue.kind=="none" ? Color.secondary:Color.primary)
                .lineLimit(1).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,6).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("表格·\(name)·\(gesture)")
    }
    private var footer:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack(spacing:12) {
                Button(store.detecting ? "结束检测":"检测实体按键") {store.detecting ? stopDetection():startDetection()}
                    .disabled(detectionTransition || capture.routeChanging).buttonStyle(.bordered)
                Button(store.enabled ? "停止接管":"启用当前方案") {
                    if store.enabled {receiver.stop();store.status="已恢复系统按键处理"}else{receiver.start()}
                }.disabled(store.detecting || detectionTransition)
                Text(store.detecting ? "只检测，不执行动作或启动录音":"启用方案后，替代遥控器原有系统动作").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength:4)
                Button("恢复默认"){confirmDefaults=true}.disabled(store.enabled || store.detecting || detectionTransition)
            }
            HStack(spacing:6){Circle().fill(store.detecting ? Color.teal:store.enabled ? Color.green:Color.secondary.opacity(0.4)).frame(width:6,height:6)
                Text(detectionTransition ? "正在准备安全检测…":store.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if detectionTransition {ProgressView().controlSize(.mini)}
            }
        }.padding(14).modifier(RemoteGlassSurface(radius:18))
    }
    private func actionBinding(_ name:String,_ gesture:String)->Binding<MappedAction> {
        let schemeID=store.selected
        return Binding(get:{
            guard let scheme=store.schemes.first(where:{$0.id==schemeID}),let b=scheme.buttons.first(where:{$0.id==name}) else{return MappedAction()}
            return gesture=="单击" ? b.single:gesture=="双击" ? b.double:b.long
        },set:{value in
            guard let s=store.schemes.firstIndex(where:{$0.id==schemeID}),let b=store.schemes[s].buttons.firstIndex(where:{$0.id==name}) else{return}
            switch gesture{case "单击":store.schemes[s].buttons[b].single=value;case "双击":store.schemes[s].buttons[b].double=value;default:store.schemes[s].buttons[b].long=value}
            store.save();saved=true
        })
    }
    private func gestureHint(_ gesture:String)->String {gesture=="单击" ? "按一下":gesture=="双击" ? "快速按两下":"按住约半秒"}
    private func startDetection(){
        resumeMappings=store.enabled;resumeAfterDetection=capture.routeControl.wantsEnabled;detectionTransition=true
        detectionTask=Task { @MainActor in
            capture.enableAutomatic(false);await capture.routeControl.waitUntilSettled()
            guard !Task.isCancelled else{return}
            detectionTransition=false
            guard capture.routeControl.state == .paused else {store.status="语音暂停未完成，暂不开始检测";return}
            receiver.start(detectOnly:true)
            if !store.detecting {capture.enableAutomatic(resumeAfterDetection)}
        }
    }
    private func stopDetection(){
        detectionTask?.cancel();detectionTask=nil;detectionTransition=false
        receiver.stop();capture.enableAutomatic(resumeAfterDetection)
        store.status="检测结束，已恢复先前设置"
        if resumeMappings {receiver.start()}
    }
}
extension MappedAction {
    var displayName:String {
        switch kind {case "shortcut":return shortcut.label;case "click":return "鼠标左键";case "volumeUp":return "音量 +";case "volumeDown":return "音量 −";case "mute":return "系统静音";case "pauseVoice":return "暂停语音";default:return "未设置"}
    }
}
private struct RemoteGlassSurface:ViewModifier {
    let radius:CGFloat
    func body(content:Content)->some View {
        content.clipShape(RoundedRectangle(cornerRadius:radius))
    }
}
struct GoogleRemoteLineArt:View {
    @Binding var selected:String
    private func point(_ x:CGFloat,_ y:CGFloat)->CGPoint {CGPoint(x:x*160,y:y*540)}
    var body:some View {
        ZStack {
            RoundedRectangle(cornerRadius:66).fill(.ultraThinMaterial).overlay(RoundedRectangle(cornerRadius:66).stroke(.primary.opacity(0.22),lineWidth:1.5)).frame(width:138,height:520).allowsHitTesting(false)
            Circle().stroke(.primary.opacity(0.28),lineWidth:1.5).frame(width:116,height:116).position(point(0.5,0.17)).allowsHitTesting(false)
            Circle().stroke(.primary.opacity(0.12),lineWidth:1).frame(width:58,height:58).position(point(0.5,0.17)).allowsHitTesting(false)
            lineButton("上","chevron.up",0.5,0.09,28)
            lineButton("下","chevron.down",0.5,0.25,28)
            lineButton("左","chevron.left",0.23,0.17,28)
            lineButton("右","chevron.right",0.77,0.17,28)
            lineButton("确定","circle",0.5,0.17,46)
            lineButton("返回","arrow.uturn.backward",0.28,0.36,38)
            lineButton("语音","mic.fill",0.72,0.36,38)
            lineButton("首页","house",0.28,0.46,38)
            lineButton("静音","speaker.slash",0.72,0.46,38)
            lineButton("YouTube","play.rectangle",0.28,0.57,38)
            lineButton("Netflix","n.square",0.72,0.57,38)
            lineButton("电源","power",0.28,0.70,29)
            lineButton("输入源","rectangle.on.rectangle",0.72,0.70,29)
            Capsule().fill(.thinMaterial).overlay(Capsule().stroke(.primary.opacity(0.18))).frame(width:32,height:90).position(point(0.95,0.32)).allowsHitTesting(false)
            lineButton("音量加","plus",0.95,0.275,26)
            lineButton("音量减","minus",0.95,0.365,26)
            Text("G").font(.system(size:20,weight:.light)).foregroundStyle(.tertiary).position(point(0.5,0.86)).allowsHitTesting(false)
        }.frame(width:160,height:540).padding(.horizontal,20).accessibilityElement(children:.contain)
    }
    private func lineButton(_ name:String,_ symbol:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat)->some View {
        let hitSize:CGFloat = ["上","下","左","右"].contains(name) ? 40 : name=="确定" ? 46:max(44,size+12)
        return Button{selected=name}label:{
            Image(systemName:symbol)
                .font(.system(size:name=="语音" ? 16:13,weight:.medium))
                .frame(width:size,height:size)
                .foregroundStyle(selected==name ? Color.teal:Color.primary.opacity(0.65))
                .background(selected==name ? Color.teal.opacity(0.13):Color.clear,in:Circle())
                .overlay(Circle().stroke(selected==name ? Color.teal:Color.primary.opacity(0.25),lineWidth:selected==name ? 2:1))
                .frame(width:hitSize,height:hitSize)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("遥控器线稿·\(name)")
            .anchorPreference(key:RemoteAnchorKey.self,value:.bounds){["remote:"+name:$0]}
            .position(point(x,y))
    }
}

private struct RemoteAnchorKey:PreferenceKey {
    static var defaultValue:[String:Anchor<CGRect>]{[:]}
    static func reduce(value:inout [String:Anchor<CGRect>],nextValue:()->[String:Anchor<CGRect>]){value.merge(nextValue(),uniquingKeysWith:{$1})}
}
