import SwiftUI
import IOKit.hid
@preconcurrency import ApplicationServices

struct MappedAction: Codable, Equatable {
    var kind="none"
    var shortcut=VoiceShortcut(keyCode:49,modifiers:0,label:"空格")
    var text=""
}
struct ButtonMapping: Codable, Identifiable, Equatable {
    var id:String
    var single=MappedAction()
    var double=MappedAction()
    var long=MappedAction()
}
struct MappingScheme: Codable, Identifiable, Equatable {
    var id=UUID()
    var name:String
    var buttons:[ButtonMapping]
}
@MainActor
final class MappingStore: ObservableObject {
    @Published var schemes:[MappingScheme]=[]
    @Published var selected=UUID()
    @Published var enabled=false
    @Published var detecting=false
    @Published var lastButton=""
    @Published var lastUsage="等待真实按键"
    @Published var deviceCount=0
    @Published var status="未接管按键；系统原有按键行为保留"
    let ids=["上","下","左","右","确定","返回","首页","音量加","音量减","静音","YouTube","Netflix","输入源","电源"]
    init(){
        if let data=UserDefaults.standard.data(forKey:"naga.schemes"),let list=try? JSONDecoder().decode([MappingScheme].self,from:data),!list.isEmpty { schemes=list }
        else { schemes=[MappingScheme(name:"默认方案",buttons:ids.map{ButtonMapping(id:$0)})] }
        if let id=UserDefaults.standard.string(forKey:"naga.activeScheme").flatMap(UUID.init(uuidString:)),schemes.contains(where:{$0.id==id}){selected=id}else{selected=schemes[0].id}
    }
    var current:Int { schemes.firstIndex(where:{$0.id==selected}) ?? 0 }
    func save(){if let data=try? JSONEncoder().encode(schemes){UserDefaults.standard.set(data,forKey:"naga.schemes")};UserDefaults.standard.set(selected.uuidString,forKey:"naga.activeScheme")}
    func resetDefaults(){schemes[current].buttons=Self.defaultButtons();save();status="已恢复内置默认方案"}
    static func defaultButtons()->[ButtonMapping] {
        let defaults:[String:(UInt16,String)]=["上":(126,"↑"),"下":(125,"↓"),"左":(123,"←"),"右":(124,"→"),"确定":(36,"回车"),"返回":(51,"删除"),"首页":(103,"F11"),"电源":(53,"Esc")]
        let ids=["上","下","左","右","确定","返回","首页","音量加","音量减","静音","YouTube","Netflix","输入源","电源"]
        return ids.map { name in
            var b=ButtonMapping(id:name)
            if let (key,label)=defaults[name] {b.single=MappedAction(kind:"shortcut",shortcut:VoiceShortcut(keyCode:key,modifiers:0,label:label))}
            if name=="音量加" {b.single.kind="volumeUp"}
            if name=="音量减" {b.single.kind="volumeDown"}
            if name=="静音" {b.single.kind="mute"}
            return b
        }
    }
    func duplicate(){var scheme=schemes[current];scheme.id=UUID();scheme.name += " 副本";schemes.append(scheme);selected=scheme.id;save()}
    func remove(){guard schemes.count>1 else{return};schemes.removeAll{$0.id==selected};selected=schemes[0].id;save()}
    func export(){let panel=NSSavePanel();panel.nameFieldStringValue="小娜迦-按键方案.json";guard panel.runModal() == .OK,let url=panel.url else{return};do{try JSONEncoder().encode(schemes[current]).write(to:url,options:.atomic)}catch{status="导出失败：\(error.localizedDescription)"}}
    func importFile(){let panel=NSOpenPanel();panel.allowsMultipleSelection=false;guard panel.runModal() == .OK,let url=panel.url else{return};do{let data=try Data(contentsOf:url);guard data.count<1_000_000 else{throw DoubaoBridge.BridgeError("文件过大")};var scheme=try JSONDecoder().decode(MappingScheme.self,from:data);guard scheme.buttons.count<=ids.count,Set(scheme.buttons.map(\.id)).count==scheme.buttons.count,scheme.buttons.allSatisfy({ids.contains($0.id)}) else{throw DoubaoBridge.BridgeError("方案按键重复或包含未知按键")}
        let kinds=Set(["none","shortcut","click","volumeUp","volumeDown","mute","pauseVoice"])
        for button in scheme.buttons { for action in [button.single,button.double,button.long] {
            guard kinds.contains(action.kind),action.shortcut.keyCode<=127,action.shortcut.label.count<=100 else {throw DoubaoBridge.BridgeError("方案包含不支持的动作")}
        }}
        scheme.name=String(scheme.name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(60));if scheme.name.isEmpty{scheme.name="导入方案"}
        scheme.buttons=ids.map { id in scheme.buttons.first(where:{$0.id==id}) ?? ButtonMapping(id:id) }
        scheme.id=UUID();schemes.append(scheme);selected=scheme.id;save()}catch{status="导入失败：\(error.localizedDescription)"}}
}

@MainActor
final class RemoteButtons {
    private var manager:IOHIDManager?
    private var gestures:[String:GestureSequence]=[:]
    private var gestureMappings:[String:ButtonMapping]=[:]
    private var gestureTimer:Timer?
    private var schemeSnapshot:MappingScheme?
    var pauseVoice:(()->Void)?
    let store:MappingStore
    init(_ store:MappingStore){self.store=store}
    func start(detectOnly:Bool=false){
        stop()
        let manager=IOHIDManagerCreate(kCFAllocatorDefault,IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager=manager
        IOHIDManagerSetDeviceMatching(manager,[kIOHIDVendorIDKey:0x18D1,kIOHIDProductIDKey:0x9450] as CFDictionary)
        let context=Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager,{ context,result,_,value in
            guard let context,result==kIOReturnSuccess else{return}
            MainActor.assumeIsolated{Unmanaged<RemoteButtons>.fromOpaque(context).takeUnretainedValue().receive(value)}
        },context)
        IOHIDManagerRegisterDeviceMatchingCallback(manager,{context,_,_,_ in
            guard let context else{return}
            MainActor.assumeIsolated{Unmanaged<RemoteButtons>.fromOpaque(context).takeUnretainedValue().refreshDevices()}
        },context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager,{context,_,_,_ in
            guard let context else{return}
            MainActor.assumeIsolated{
                let receiver=Unmanaged<RemoteButtons>.fromOpaque(context).takeUnretainedValue()
                receiver.clearGestures();receiver.refreshDevices()
            }
        },context)
        IOHIDManagerScheduleWithRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue)
        let result=IOHIDManagerOpen(manager,IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result==kIOReturnSuccess else{stop();store.status="按键接口打开失败：\(result)，请检查输入监控权限";return}
        store.detecting=detectOnly;store.enabled = !detectOnly
        refreshDevices()
        let timer=Timer(timeInterval:0.025,repeats:true){[weak self]_ in MainActor.assumeIsolated{self?.advanceGestures()}}
        RunLoop.main.add(timer,forMode:.common);gestureTimer=timer
    }
    private func refreshDevices(){
        guard let manager else{return}
        store.deviceCount=(IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.count ?? 0
        store.status=store.deviceCount==0 ? "等待遥控器 HID 接口，连接后自动恢复":store.detecting ? "检测中：只显示按键，不执行映射或启动语音":"已接管遥控器按键，使用当前方案"
    }
    private func clearGestures(){gestures=[:];gestureMappings=[:]}
    func stop(){
        clearGestures();gestureTimer?.invalidate();gestureTimer=nil
        if let manager{IOHIDManagerUnscheduleFromRunLoop(manager,CFRunLoopGetMain(),CFRunLoopMode.commonModes.rawValue);IOHIDManagerClose(manager,IOOptionBits(kIOHIDOptionsTypeNone))}
        manager=nil;store.enabled=false;store.detecting=false;store.deviceCount=0
    }
    private func receive(_ value:IOHIDValue){
        let element=IOHIDValueGetElement(value);let page=IOHIDElementGetUsagePage(element);let usage=IOHIDElementGetUsage(element)
        let keyboard:[UInt32:String]=[0x4f:"右",0x50:"左",0x51:"下",0x52:"上",0x28:"确定",0x29:"返回",0x4a:"首页"]
        let consumer:[UInt32:String]=[0x19e:"电源",0x42:"上",0x43:"下",0x44:"左",0x45:"右",0x41:"确定",0x77:"YouTube",0x78:"Netflix",0x89:"输入源",0xe9:"音量加",0xea:"音量减",0xe2:"静音",0xcd:"确定",0x223:"首页",0x224:"返回",0x30:"电源"]
        guard let name=page==7 ? keyboard[usage] : page==12 ? consumer[usage] : nil else{return}
        let down=IOHIDValueGetIntegerValue(value) != 0
        if down {store.lastButton=name;store.lastUsage="\(name) · HID \(page):\(String(usage,radix:16))"}
        if !store.detecting {edge(name,down:down)}
    }
    func edge(_ name:String,down:Bool){
        guard store.enabled else{return}
        let snapshot=store.schemes[store.current]
        if snapshot != schemeSnapshot {clearGestures();schemeSnapshot=snapshot}
        guard let mapping=store.schemes[store.current].buttons.first(where:{$0.id==name}) else{return}
        if gestures[name]==nil {
            gestures[name]=GestureSequence(doubleEnabled:mapping.double.kind != "none",longEnabled:mapping.long.kind != "none")
            gestureMappings[name]=mapping
        }
        guard var gesture=gestures[name] else{return}
        let effects=down ? gesture.down(at:ProcessInfo.processInfo.systemUptime):gesture.up(at:ProcessInfo.processInfo.systemUptime)
        gestures[name]=gesture
        for effect in effects {perform(effect,button:name)}
    }
    private func advanceGestures(){
        let snapshot=store.schemes[store.current]
        if snapshot != schemeSnapshot {clearGestures();schemeSnapshot=snapshot}
        for name in Array(gestures.keys) {
            guard var gesture=gestures[name] else{continue}
            let effects=gesture.advance(to:ProcessInfo.processInfo.systemUptime);gestures[name]=gesture
            for effect in effects {perform(effect,button:name)}
        }
    }
    private func perform(_ gesture:GestureSequence.Gesture,button:String){
        guard let mapping=gestureMappings[button] else{return}
        switch gesture {case .single:execute(mapping.single);case .double:execute(mapping.double);case .long:execute(mapping.long)}
    }
    private func execute(_ action:MappedAction){
        guard AXIsProcessTrusted() else{store.status="执行映射需要辅助功能权限";return}
        let source=CGEventSource(stateID:.privateState)
        switch action.kind{
        case "shortcut":
            for down in [true,false]{if let event=CGEvent(keyboardEventSource:source,virtualKey:action.shortcut.keyCode,keyDown:down){event.flags=CGEventFlags(rawValue:action.shortcut.modifiers);event.setIntegerValueField(.eventSourceUserData,value:0x4E414741);event.post(tap:.cghidEventTap)}}
        case "click":
            guard let location=CGEvent(source:nil)?.location else{return}
            CGEvent(mouseEventSource:source,mouseType:.leftMouseDown,mouseCursorPosition:location,mouseButton:.left)?.post(tap:.cghidEventTap)
            CGEvent(mouseEventSource:source,mouseType:.leftMouseUp,mouseCursorPosition:location,mouseButton:.left)?.post(tap:.cghidEventTap)
        case "volumeUp":SystemAudio.adjust(0.0625)
        case "volumeDown":SystemAudio.adjust(-0.0625)
        case "mute":SystemAudio.toggleMute()
        case "pauseVoice":pauseVoice?()
        default:break
        }
    }
}
