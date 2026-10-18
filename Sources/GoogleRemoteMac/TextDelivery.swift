import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class TextDelivery {
    private var target: NSRunningApplication?
    private var element: AXUIElement?
    private var selection: CFTypeRef?
    private var liveRange: CFRange?
    private var liveText = ""
    private var liveBlocked = false
    var trusted: Bool { AXIsProcessTrusted() }
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func capture() -> String? {
        target = nil; element = nil; selection = nil; liveRange=nil;liveText="";liveBlocked=false
        guard trusted else { return "请先在辅助功能中允许本应用输入文字" }
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return "请把光标放到其他应用的文本输入框，再按语音键"
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return "无法确认当前输入框；识别文字会保留供复制" }
        let field = unsafeDowncast(focused, to: AXUIElement.self)
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &range) == .success else {
            return "当前控件未提供文本光标位置；识别文字会保留供复制"
        }
        target = app; element = field; selection = range
        return nil
    }
    func updateLive(_ text:String) -> Bool {
        guard !liveBlocked,trusted,let target,let element,let selection,
              NSWorkspace.shared.frontmostApplication?.processIdentifier==target.processIdentifier else { liveBlocked=true;return false }
        var focus:CFTypeRef?;var caret:CFTypeRef?
        let app=AXUIElementCreateApplication(target.processIdentifier)
        guard AXUIElementCopyAttributeValue(app,kAXFocusedUIElementAttribute as CFString,&focus) == .success,
              let focus,CFEqual(focus,element),
              AXUIElementCopyAttributeValue(element,kAXSelectedTextRangeAttribute as CFString,&caret) == .success,
              let caret,CFGetTypeID(caret)==AXValueGetTypeID() else { liveBlocked=true;return false }
        var actual=CFRange()
        guard AXValueGetValue(unsafeDowncast(caret,to:AXValue.self),.cfRange,&actual) else { return false }
        var settable:DarwinBoolean=false
        guard AXUIElementIsAttributeSettable(element,kAXSelectedTextAttribute as CFString,&settable) == .success,settable.boolValue else { return false }
        var owned:CFRange
        if let previous=liveRange {
            guard actual.location==previous.location+previous.length,actual.length==0 else { liveBlocked=true;return false }
            var check=previous
            guard let value=AXValueCreate(.cfRange,&check) else { return false }
            var stored:CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element,kAXStringForRangeParameterizedAttribute as CFString,value,&stored) == .success,
                  let stored,CFGetTypeID(stored)==CFStringGetTypeID(),(stored as! String)==liveText else { liveBlocked=true;return false }
            owned=previous
        } else {
            guard CFEqual(caret,selection) else { liveBlocked=true;return false }
            owned=actual
        }
        var replace=owned
        guard let rangeValue=AXValueCreate(.cfRange,&replace),
              AXUIElementSetAttributeValue(element,kAXSelectedTextRangeAttribute as CFString,rangeValue) == .success else { return false }
        guard AXUIElementSetAttributeValue(element,kAXSelectedTextAttribute as CFString,text as CFString) == .success else {
            if var restore=liveRange.map({ CFRange(location:$0.location+$0.length,length:0) }) {
                if let value=AXValueCreate(.cfRange,&restore) { _=AXUIElementSetAttributeValue(element,kAXSelectedTextRangeAttribute as CFString,value) }
            }
            liveBlocked=true;return false
        }
        liveRange=CFRange(location:owned.location,length:text.utf16.count);liveText=text
        var end=CFRange(location:owned.location+text.utf16.count,length:0)
        if let value=AXValueCreate(.cfRange,&end) { _=AXUIElementSetAttributeValue(element,kAXSelectedTextRangeAttribute as CFString,value) }
        return true
    }
    func deliver(_ text: String) -> String {
        guard liveRange == nil else { return liveBlocked ? "光标或文本已变化，后续文字请在预览中复制" : "流式文字已输入" }
        guard !text.isEmpty else { return "没有识别到文字" }
        guard trusted, let target, let element, let selection else { return "文字已识别，未自动输入；可在窗口中复制" }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else { return "你已切换应用，文字保留供复制" }
        var focus: CFTypeRef?; var range: CFTypeRef?
        let app = AXUIElementCreateApplication(target.processIdentifier)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focus) == .success,
              let focus, CFEqual(focus, element),
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range, CFEqual(range, selection) else { return "光标位置已变化，文字保留供复制" }
        // Unicode keyboard events avoid altering the clipboard or sending Return.
        var chunks: [[UniChar]] = []; var chunk: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if chunk.count + units.count > 20 && !chunk.isEmpty { chunks.append(chunk); chunk = [] }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        guard let source = CGEventSource(stateID: .privateState) else { return "无法创建输入事件，文字保留供复制" }
        for units in chunks {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return "输入事件失败，请核对输入框；文字仍保留" }
            units.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress { down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base); up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base) }
            }
            down.flags=[];up.flags=[];down.setIntegerValueField(.eventSourceUserData,value:0x4E414741);up.setIntegerValueField(.eventSourceUserData,value:0x4E414741)
            down.postToPid(target.processIdentifier); up.postToPid(target.processIdentifier)
        }
        self.target = nil; self.element = nil; self.selection = nil
        return "文字已发送到原输入位置"
    }
}
