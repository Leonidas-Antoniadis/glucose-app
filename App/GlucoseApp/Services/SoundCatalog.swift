import Foundation
import AVFoundation
import Observation
import UserNotifications
import GlucoseCore

/// Maps alert sound styles to audio files. Bundled files sit in the app bundle; imported
/// tunes are copied to Library/Sounds, where iOS also looks for notification sounds.
enum SoundCatalog {
    struct Option: Hashable, Identifiable {
        let id: String
        let title: String
    }

    static let tunes: [Option] = [
        Option(id: "alarm_loud_low", title: "Ultra loud low (piercing beeps)"),
        Option(id: "alarm_loud_high", title: "Ultra loud high (piercing siren)"),
        Option(id: "alarm_low", title: "Low alarm (urgent, falling tones)"),
        Option(id: "alarm_high", title: "High alarm (rising two-tone)"),
        Option(id: "chime", title: "Chime"),
        Option(id: "pulse", title: "Pulse"),
    ]

    static let voiceClips: [Option] = [
        Option(id: "glucose_low", title: "\"Glucose low\""),
        Option(id: "glucose_very_low", title: "\"Glucose very low\""),
        Option(id: "urgent_low", title: "\"Urgent low glucose. Treat now.\""),
        Option(id: "glucose_high", title: "\"Glucose high\""),
        Option(id: "glucose_very_high", title: "\"Glucose very high\""),
        Option(id: "falling_fast", title: "\"Glucose falling fast\""),
        Option(id: "rising_fast", title: "\"Glucose rising fast\""),
        Option(id: "low_soon", title: "\"Glucose will be low soon\""),
        Option(id: "no_data", title: "\"No glucose data\""),
    ]

    static let customPrefix = "custom:"

    static var soundsDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Sounds", isDirectory: true)
    }

    /// Imported tunes, as options whose id is `custom:<file name>`.
    static func customTunes() -> [Option] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: soundsDirectory.path)) ?? []
        return names.sorted().map { Option(id: customPrefix + $0, title: ($0 as NSString).deletingPathExtension) }
    }

    /// Converts an audio file to 16-bit linear PCM in a .caf file in Library/Sounds and returns its
    /// tune id. Notifications only play PCM, IMA4, µLaw or aLaw sounds: an MP3 or M4A copied as it
    /// is previews fine but the alert plays the default sound.
    static func importTune(from url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: url)
        } catch {
            throw ImportError.unreadable
        }
        let duration = Double(input.length) / input.fileFormat.sampleRate
        guard duration > 0 else { throw ImportError.unreadable }
        guard duration <= 30 else { throw ImportError.tooLong(duration) }

        try FileManager.default.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        let baseName = (url.lastPathComponent.replacingOccurrences(of: " ", with: "_") as NSString).deletingPathExtension
        let fileName = baseName + ".caf"
        let destination = soundsDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)
        do {
            try transcode(input, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.unreadable
        }
        return customPrefix + fileName
    }

    private static func transcode(_ input: AVAudioFile, to destination: URL) throws {
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // The file is finished when `output` goes away at the end of this function.
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else { throw ImportError.unreadable }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    enum ImportError: LocalizedError {
        case tooLong(TimeInterval)
        case unreadable
        var errorDescription: String? {
            switch self {
            case .tooLong(let seconds): return "iOS plays alert sounds of up to 30 seconds. This file is \(Int(seconds)) seconds."
            case .unreadable: return "This file can't be played as an alert sound. Try an MP3, M4A, WAV or AIFF file."
            }
        }
    }

    static func fileName(for style: SoundStyle) -> String? {
        switch style {
        case .silent: return nil
        case .tune(let name):
            return name.hasPrefix(customPrefix) ? String(name.dropFirst(customPrefix.count)) : "tune_\(name).wav"
        case .voice(let clip): return "voice_\(clip).wav"
        }
    }

    static func url(for style: SoundStyle) -> URL? {
        guard let file = fileName(for: style) else { return nil }
        if let bundled = Bundle.main.url(forResource: file, withExtension: nil) { return bundled }
        let custom = soundsDirectory.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: custom.path) ? custom : nil
    }

    static func title(for style: SoundStyle) -> String {
        switch style {
        case .silent: return "Silent"
        case .tune(let name):
            let all = tunes + customTunes()
            return "Tune: " + (all.first { $0.id == name }?.title ?? name)
        case .voice(let clip):
            return "Voice: " + (voiceClips.first { $0.id == clip }?.title ?? clip)
        }
    }

    /// A sound that can actually play. An imported tune whose file is missing (for example after
    /// restoring a backup on a new phone) is replaced by `fallback`: without this the notification
    /// would use the iOS default sound, which Silent mode mutes.
    static func playable(_ style: SoundStyle, fallback: SoundStyle) -> SoundStyle {
        guard style != .silent, url(for: style) == nil else { return style }
        return fallback
    }

    /// The bundled alarm for a direction, used when nothing else can play.
    static func alarm(for direction: AlertDirection) -> SoundStyle {
        .tune(name: direction == .low ? "alarm_loud_low" : "alarm_high")
    }

    /// Whether this tune's file is missing on this phone.
    static func isMissing(_ style: SoundStyle) -> Bool {
        style != .silent && url(for: style) == nil
    }

    static func notificationSound(for style: SoundStyle, critical: Bool, volume: Double) -> UNNotificationSound? {
        guard let file = fileName(for: style) else { return critical ? .defaultCritical : nil }
        let name = UNNotificationSoundName(rawValue: file)
        return critical ? .criticalSoundNamed(name, withAudioVolume: Float(volume)) : UNNotificationSound(named: name)
    }
}

/// Plays a sound preview in the rule editor. `playing` drives the Play/Stop button.
@MainActor
@Observable
final class SoundPreviewPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = SoundPreviewPlayer()
    @ObservationIgnored private var player: AVAudioPlayer?
    private(set) var playing: SoundStyle?

    func play(_ style: SoundStyle) {
        player?.stop()
        guard let url = SoundCatalog.url(for: style) else { return }
        // .playback sounds even when the ring/silent switch is on silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.volume = 1
        playing = player?.play() == true ? style : nil
    }

    func stop() {
        let wasPlaying = player != nil
        player?.stop()
        player = nil
        playing = nil
        // The audio session is shared: deactivating it while an alarm plays would cut the alarm off.
        if wasPlaying, !AlarmPlayer.isActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player { self.stop() }
        }
    }
}

/// Plays an alarm from the app itself. App audio ignores the Silent switch and Focus, so this is how
/// an alert marked Critical breaks through before Apple grants the Critical Alerts entitlement.
/// Works while the app runs (foreground, or background with Bluetooth readings and "Run in background").
@MainActor
final class AlarmPlayer {
    /// True while an alarm plays, so a sound preview never deactivates the audio session under it.
    private(set) static var isActive = false

    /// Whether an alarm the app plays is clearly heard: media volume at least half and the
    /// built-in speaker. Otherwise the notification keeps its own sound, which plays at ringer volume.
    static var isClearlyAudible: Bool {
        let session = AVAudioSession.sharedInstance()
        return session.outputVolume >= 0.5 && session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }

    /// Called when an interrupted alarm (a call, Siri, a Clock timer) couldn't be resumed.
    var onResumeFailed: (() -> Void)?

    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            MainActor.assumeIsolated { self?.interruption(type) }
        }
    }

    /// Loops the sound for up to `seconds`. Returns false if it couldn't start. A running alarm is
    /// only replaced once the new one is playing, so a failed start never silences it.
    func play(_ style: SoundStyle, seconds: Double = 30) -> Bool {
        guard let url = SoundCatalog.url(for: style), let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return false }
        do {
            // .playback ignores the ring/silent switch; ducking lets it start from the background.
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            return false
        }
        newPlayer.numberOfLoops = -1
        newPlayer.volume = 1
        guard newPlayer.play() else { return false }
        stopTask?.cancel()
        player?.stop()
        player = newPlayer
        Self.isActive = true
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
        return true
    }

    var isPlaying: Bool { player?.isPlaying == true }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        Self.isActive = false
        guard let player else { return }
        player.stop()
        self.player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// A call, Siri or a Clock alarm pauses the alarm. When it ends, the alarm resumes for the rest
    /// of its time; if it can't, the app is told so it can send the alert again with a sound.
    private func interruption(_ type: AVAudioSession.InterruptionType?) {
        guard type == .ended, let player, stopTask != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if !player.play() { onResumeFailed?() }
    }
}
