import Foundation
struct RemoteModeGate {
    enum Effect:Equatable { case consume(Data),write(Data),finish }
    var active=false
    var waitingForSoftware=false
    var stream:UInt8=0
    mutating func reset(){active=false;waitingForSoftware=false;stream=0}
    mutating func control(_ data:Data)->[Effect]{
        let p=Array(data)
        guard let op=p.first else{return []}
        if op==4 {
            guard p.count==4,p[2]==2 else {let effects=active ? [Effect.finish]:[];reset();return effects}
            if p[1]==3 {
                if active {
                    let effects:[Effect]=[.write(Data([0x0d,stream])),.write(Data([0x0d,p[3]])),.finish];reset();return effects
                }
                active=true;waitingForSoftware=true;stream=p[3];return [.consume(data)]
            }
            if p[1]==0,p[3]==0,active {waitingForSoftware=false;stream=0;return [.consume(data)]}
            return []
        }
        if op==0,active {
            if waitingForSoftware,p.count==2,p[1]==2 {return [.write(Data([0x0c,0]))]}
            reset();return [.finish]
        }
        if op==10,active {return [.consume(data)]}
        if op==0x0c,active {reset();return [.finish]}
        return []
    }
}
