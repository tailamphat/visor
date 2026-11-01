import CoreAudio
import Foundation

/// Tells MusicService when any app starts or stops sending sound to the
/// speakers, using Core Audio's own change notifications instead of asking
/// every second. With nothing playing and nothing changing, it does no work.
@MainActor
final class AudioOutputWatcher {
    var onChange: (() -> Void)?

    private var processListener: AudioObjectPropertyListenerBlock?
    /// One "is it playing?" listener per audio process.
    private var outputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var pending = false

    private static var processList = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                               mScope: kAudioObjectPropertyScopeGlobal,
                                                               mElement: kAudioObjectPropertyElementMain)
    private static var runningOutput = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                                 mElement: kAudioObjectPropertyElementMain)

    func start() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.watchProcesses()
                self?.changed()
            }
        }
        processListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.processList, .main, listener)
        watchProcesses()
    }

    /// Keeps a listener on every current audio process, and drops gone ones.
    private func watchProcesses() {
        let current = Set(Self.processes())
        for (process, listener) in outputListeners where !current.contains(process) {
            AudioObjectRemovePropertyListenerBlock(process, &Self.runningOutput, .main, listener)
            outputListeners[process] = nil
        }
        for process in current where outputListeners[process] == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.changed() }
            }
            if AudioObjectAddPropertyListenerBlock(process, &Self.runningOutput, .main, listener) == noErr {
                outputListeners[process] = listener
            }
        }
    }

    /// Several processes often change together; report once.
    private func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.pending = false
                self?.onChange?()
            }
        }
    }

    static func processes() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &processList, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &processList, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }
}
