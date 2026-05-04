import Foundation
import CoreAudio
import AVFoundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDeviceManager {
    /// All currently-available audio input devices (anything with at least one input stream).
    static func availableInputs() -> [AudioInputDevice] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }

        var out: [AudioInputDevice] = []
        for id in ids {
            guard hasInputStreams(id) else { continue }
            guard let name = stringProperty(id, selector: kAudioObjectPropertyName),
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
            else { continue }
            out.append(AudioInputDevice(id: id, uid: uid, name: name))
        }
        return out
    }

    /// Resolve a device by its UID (persisted across launches; AudioDeviceID can change).
    static func device(forUID uid: String) -> AudioInputDevice? {
        availableInputs().first(where: { $0.uid == uid })
    }

    /// Currently configured system default input device.
    static func defaultInput() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown,
              let name = stringProperty(deviceID, selector: kAudioObjectPropertyName),
              let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioInputDevice(id: deviceID, uid: uid, name: name)
    }

    // MARK: - Private

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let s = value else { return nil }
        return s as String
    }
}
