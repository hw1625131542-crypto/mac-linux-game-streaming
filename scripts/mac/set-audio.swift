// ============================================================================
//  Mac：切换默认音频输出设备（命令行小工具）
//
//  为什么需要：
//    Mac 的默认输出设备经常是外接显示器（走 DisplayPort/HDMI 音频）。
//    如果那台显示器没接音响、或者没开音量，串流就是「有画面没声音」。
//    这个工具让你用一行命令切换，不用去点系统设置。
//
//  编译 & 使用：
//      swiftc -O set-audio.swift -o set-audio
//      ./set-audio                  # 列出所有可输出设备（带 ← 标记当前默认）
//      ./set-audio "MacBook"        # 切到名字里含 "MacBook" 的设备
//      ./set-audio "DELL"           # 切到名字里含 "DELL" 的（比如显示器）
//
//  注：设备名字是本地化的，中文系统下可能显示成「MacBook Air扬声器」，
//      所以用关键字匹配而不是全名。
// ============================================================================
import CoreAudio
import Foundation

let sys = AudioObjectID(kAudioObjectSystemObject)

func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel,
                               mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func deviceName(_ id: AudioDeviceID) -> String {
    var a = addr(kAudioObjectPropertyName)
    var s = UInt32(MemoryLayout<CFString?>.size)
    var cf: CFString? = nil
    let r = withUnsafeMutablePointer(to: &cf) { p -> OSStatus in
        AudioObjectGetPropertyData(id, &a, 0, nil, &s, p)
    }
    guard r == noErr, let v = cf else { return "?" }
    return v as String
}

/// 这个设备有没有输出声道（音箱/耳机）
func hasOutput(_ id: AudioDeviceID) -> Bool {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                       mScope: kAudioObjectPropertyScopeOutput,
                                       mElement: kAudioObjectPropertyElementMain)
    var s = UInt32(0)
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &s) == noErr, s > 0 else { return false }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(s), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, buf) == noErr else { return false }
    let abl = buf.assumingMemoryBound(to: AudioBufferList.self)
    let items = UnsafeMutableAudioBufferListPointer(abl)
    var ch = 0
    for i in 0..<Int(abl.pointee.mNumberBuffers) { ch += Int(items[i].mNumberChannels) }
    return ch > 0
}

// 列出所有设备
var a = addr(kAudioHardwarePropertyDevices)
var size = UInt32(0)
AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size)
let cnt = Int(size) / MemoryLayout<AudioDeviceID>.size
var ids = [AudioDeviceID](repeating: 0, count: cnt)
AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids)

// 当前默认输出
var cur = AudioDeviceID(0)
var cs = UInt32(MemoryLayout<AudioDeviceID>.size)
var ca = addr(kAudioHardwarePropertyDefaultOutputDevice)
AudioObjectGetPropertyData(sys, &ca, 0, nil, &cs, &cur)

print("当前默认输出: \(deviceName(cur))")
print("--- 所有可输出设备 ---")
for id in ids where hasOutput(id) {
    print("  \(deviceName(id))\(id == cur ? "  ←当前" : "")")
}

// 切换
let args = CommandLine.arguments
if args.count > 1 {
    let want = args[1].lowercased()
    for id in ids where hasOutput(id) {
        if deviceName(id).lowercased().contains(want) {
            var dev = id
            var sa = addr(kAudioHardwarePropertyDefaultOutputDevice)
            let r = AudioObjectSetPropertyData(sys, &sa, 0, nil,
                                               UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
            if r == noErr {
                print("✅ 已切换默认输出到: \(deviceName(id))")
            } else {
                print("❌ 切换失败 OSStatus=\(r)")
            }
            exit(0)
        }
    }
    print("❌ 没找到名字含「\(args[1])」的输出设备")
}
