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

    /// Copies an audio file into Library/Sounds and returns its tune id.
    static func importTune(from url: URL) throws -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        let safeName = url.lastPathComponent.replacingOccurrences(of: " ", with: "_")
        let destination = soundsDirectory.appendingPathComponent(safeName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
        let duration = (try? AVAudioPlayer(contentsOf: destination))?.duration ?? 0
        if duration > 30 {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.tooLong(duration)
        }
        return customPrefix + safeName
    }

    enum ImportError: LocalizedError {
        case tooLong(TimeInterval)
        var errorDescription: String? {
            switch self {
            case .tooLong(let seconds): return "iOS plays alert sounds of up to 30 seconds. This file is \(Int(seconds)) seconds."
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
        player?.stop()
        player = nil
        playing = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if self.player === player { self.stop() }
        }
    }
}
