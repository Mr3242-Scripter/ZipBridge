import Foundation
import AVFoundation
import CoreLocation
import UIKit

/// Keeps the app alive in the background during long uploads.
/// - Silent audio: continuous near-silent playback (UIBackgroundModes audio)
/// - Location: brief location update every 5 seconds (UIBackgroundModes location)
@MainActor
final class BackgroundKeepAlive: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeepAlive()

    private var audioPlayer: AVAudioPlayer?
    private var locationManager: CLLocationManager?
    private var locationTimer: Timer?
    private var isAudioActive = false
    private var isLocationActive = false

    private override init() {
        super.init()
    }

    // MARK: - Public control

    func apply(audioEnabled: Bool, locationEnabled: Bool, uploading: Bool) {
        if uploading && audioEnabled {
            startAudio()
        } else {
            stopAudio()
        }

        if uploading && locationEnabled {
            startLocation()
        } else {
            stopLocation()
        }
    }

    func stopAll() {
        stopAudio()
        stopLocation()
    }

    // MARK: - Silent audio

    private func startAudio() {
        guard !isAudioActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            // Tiny near-silent WAV (very low amplitude) generated in memory.
            let data = Self.makeNearSilentWav(durationSeconds: 2, sampleRate: 8000)
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1
            player.volume = 0.01
            player.prepareToPlay()
            player.play()
            audioPlayer = player
            isAudioActive = true
        } catch {
            // Best-effort; upload continues without background audio.
            isAudioActive = false
            audioPlayer = nil
        }
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        isAudioActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Minimal mono 8-bit PCM WAV with near-zero samples.
    private static func makeNearSilentWav(durationSeconds: Int, sampleRate: Int) -> Data {
        let numSamples = durationSeconds * sampleRate
        var data = Data()

        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        let dataSize = UInt32(numSamples) // 8-bit mono
        let fileSize = 36 + dataSize

        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // RIFF
        appendUInt32(fileSize)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // WAVE
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // fmt 
        appendUInt32(16)
        appendUInt16(1) // PCM
        appendUInt16(1) // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate)) // byte rate
        appendUInt16(1) // block align
        appendUInt16(8) // bits
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // data
        appendUInt32(dataSize)

        // Near silence (128 = midpoint for unsigned 8-bit PCM)
        data.append(contentsOf: repeatElement(UInt8(128), count: numSamples))
        return data
    }

    // MARK: - Location ping every 5 seconds

    private func startLocation() {
        guard !isLocationActive else { return }

        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false

        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestAlwaysAuthorization()
        }

        if status == .authorizedAlways || status == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }

        locationManager = manager
        isLocationActive = true

        // Re-request a location every 5 seconds to keep the process warm.
        locationTimer?.invalidate()
        locationTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.locationManager?.requestLocation()
            }
        }
        if let locationTimer {
            RunLoop.main.add(locationTimer, forMode: .common)
        }
    }

    private func stopLocation() {
        locationTimer?.invalidate()
        locationTimer = nil
        locationManager?.stopUpdatingLocation()
        locationManager = nil
        isLocationActive = false
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = manager.authorizationStatus
            if self.isLocationActive,
               status == .authorizedAlways || status == .authorizedWhenInUse {
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Intentional no-op: updates only keep the process alive.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore failures; upload continues.
    }
}
