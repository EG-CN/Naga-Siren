import CoreAudio
import AudioToolbox
@MainActor enum SystemAudio {
    private static func output()->AudioDeviceID? {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
        var id=AudioDeviceID(0);var size=UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&id)==noErr ? id:nil
    }
    static func adjust(_ amount:Float) {
        guard let id=output() else{return}
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwareServiceDeviceProperty_VirtualMainVolume,mScope:kAudioDevicePropertyScopeOutput,mElement:0)
        var value:Float=0;var size=UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(id,&address,0,nil,&size,&value)==noErr else{return}
        value=max(0,min(1,value+amount));_ = AudioObjectSetPropertyData(id,&address,0,nil,size,&value)
    }
    static func toggleMute(){
        guard let id=output() else{return}
        var address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyMute,mScope:kAudioDevicePropertyScopeOutput,mElement:0)
        var value:UInt32=0;var size=UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id,&address,0,nil,&size,&value)==noErr else{return}
        value=value==0 ? 1:0;_ = AudioObjectSetPropertyData(id,&address,0,nil,size,&value)
    }
}
