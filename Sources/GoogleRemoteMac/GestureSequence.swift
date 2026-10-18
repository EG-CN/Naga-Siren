struct GestureSequence {
    enum Gesture:Equatable {case single,double,long}
    let doubleEnabled:Bool
    let longEnabled:Bool
    private var isDown=false
    private var downAt=0.0
    private var secondPress=false
    private var longFired=false
    private var pendingSingle:Double?
    mutating func down(at now:Double)->[Gesture]{
        guard !isDown else{return []}
        var result:[Gesture]=[]
        if let deadline=pendingSingle {
            if now<=deadline {secondPress=true}
            else {result.append(.single);secondPress=false}
            pendingSingle=nil
        }else{secondPress=false}
        isDown=true;downAt=now;longFired=false
        return result
    }
    mutating func up(at now:Double)->[Gesture]{
        guard isDown else{return []}
        let result=advance(to:now)
        isDown=false
        if longFired {secondPress=false;return result}
        if secondPress {secondPress=false;return result+[.double]}
        if doubleEnabled {pendingSingle=now+0.28;return result}
        return result+[.single]
    }
    mutating func advance(to now:Double)->[Gesture]{
        if isDown,longEnabled,!longFired,now-downAt>=0.55 {
            longFired=true;pendingSingle=nil;secondPress=false;return [.long]
        }
        if !isDown,let deadline=pendingSingle,now>=deadline {pendingSingle=nil;return [.single]}
        return []
    }
}
enum VoiceModifierState {
    static func isDown(_ key:UInt16,flags:UInt64,required:UInt64)->Bool {
        let side:[UInt16:UInt64]=[54:0x10,55:0x08,56:0x02,60:0x04,58:0x20,61:0x40,59:0x01,62:0x2000]
        if let mask=side[key] {return flags & mask != 0}
        return flags & required == required
    }
}
