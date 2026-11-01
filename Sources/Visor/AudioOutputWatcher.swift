import CoreAudio
import Foundation

/// Tells MusicService when sound may have started or stopped, cheaply.
///
/// Core Audio doesn't notify when an app that already has an audio process
/// pauses or resumes (Dia's helper, say): per-process "running output"
/// listeners never fire. What does notify: the list of audio processes
/// changing, and the output device starting or stopping altogether. So:
/// - those two notifications report changes at once;
/// - while the output device is running, a light check every 3 s catches one
///   app pausing while another keeps playing;
/// - while nothing plays, there is no timer at all.
@MainActor
final class AudioOutputWatcher {
    var onChange: (() -> Void)?

    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var poll: Timer?
    private var pending = false

    func start() {
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.watchDevice()
        }
        watchDevice()
    }

    /// Follows the current output device (speakers, headphones, AirPlay).
    private func watchDevice() {
        if device != kAudioObjectUnknown {
            listeners.removeAll { entry in
                guard entry.0 == device else { return false }
                var address = entry.1
                AudioObjectRemovePropertyListenerBlock(entry.0, &address, .main, entry.2)
                return true
            }
        }
        device = Self.defaultOutputDevice()
        if device != kAudioObjectUnknown {
            listen(device, kAudioDevicePropertyDeviceIsRunningSomewhere)
        }
        changed()
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, then: (() -> Void)? = nil) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                then?()
                self?.changed()
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    /// Several notifications often arrive together; report once, and start or
    /// stop the light check depending on whether anything is playing.
    private func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                self.updatePoll()
                self.onChange?()
            }
        }
    }

    private func updatePoll() {
        let running = Self.isRunning(device)
        if running, poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updatePoll()
                    self?.onChange?()
                }
            }
            poll?.tolerance = 1
        } else if !running, let timer = poll {
            timer.invalidate()
            poll = nil
        }
    }

    static func defaultOutputDevice() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    /// Whether any app is sending sound to the device right now.
    static func isRunning(_ device: AudioObjectID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    static func processes() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }
}
