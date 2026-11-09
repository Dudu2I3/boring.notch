//
//  SpotifyController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import Combine
import SwiftUI

class SpotifyController: MediaControllerProtocol {
    // MARK: - Properties
    @Published private var playbackState: PlaybackState = PlaybackState(
        bundleIdentifier: "com.spotify.client"
    )
    
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        return true
    }

    /// Likes go through the Spotify Web API, so they only work once the user has connected their account.
    var supportsFavorite: Bool { SpotifyAuthManager.shared.hasCredentials }

    // Favorite (liked) state of the current track. Only touched on the main actor.
    private var currentTrackID: String?
    private var favoriteTrackID: String?  // track that `cachedFavorite` belongs to
    private var cachedFavorite = false
    private var favoriteFetchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private var notificationTask: Task<Void, Never>?
    
    // Constant for time between command and update
    private let commandUpdateDelay: Duration = .milliseconds(25)

    private var lastArtworkURL: String?
    private var artworkFetchTask: Task<Void, Never>?
    
    init() {
        setupPlaybackStateChangeObserver()

        // Connecting / disconnecting Spotify changes whether likes are available.
        SpotifyAuthManager.shared.$isConnected
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.updatePlaybackInfo() }
            }
            .store(in: &cancellables)

        Task {
            if isActive() {
                await updatePlaybackInfo()
            }
        }
    }
    
    private func setupPlaybackStateChangeObserver() {
        notificationTask = Task { @Sendable [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.spotify.client.PlaybackStateChanged")
            )
            
            for await _ in notifications {
                await self?.updatePlaybackInfo()
            }
        }
    }
    
    deinit {
        notificationTask?.cancel()
        artworkFetchTask?.cancel()
        favoriteFetchTask?.cancel()
    }
    
    // MARK: - Protocol Implementation
    func play() async { await executeCommand("play") }
    func pause() async { await executeCommand("pause") }
    func togglePlay() async { await executeCommand("playpause") }
    func nextTrack() async { await executeCommand("next track") }
    func previousTrack() async {
        await executeAndRefresh("previous track")
    }
    
    func seek(to time: Double) async {
        await executeAndRefresh("set player position to \(time)")
    }
    
    func toggleShuffle() async {
        await executeAndRefresh("set shuffling to not shuffling")
    }
    
    func toggleRepeat() async {
        await executeAndRefresh("set repeating to not repeating")
    }
    
    func setVolume(_ level: Double) async {
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        await executeCommand("set sound volume to \(volumePercentage)")
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }
    
    func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == playbackState.bundleIdentifier }
    }
    
    func updatePlaybackInfo() async {
        guard let descriptor = try? await fetchPlaybackInfoAsync() else { return }
        guard descriptor.numberOfItems >= 10 else { return }
        
        let isPlaying = descriptor.atIndex(1)?.booleanValue ?? false
        let currentTrack = descriptor.atIndex(2)?.stringValue ?? "Unknown"
        let currentTrackArtist = descriptor.atIndex(3)?.stringValue ?? "Unknown"
        let currentTrackAlbum = descriptor.atIndex(4)?.stringValue ?? "Unknown"
        let currentTime = descriptor.atIndex(5)?.doubleValue ?? 0
        let duration = (descriptor.atIndex(6)?.doubleValue ?? 0)/1000
        let isShuffled = descriptor.atIndex(7)?.booleanValue ?? false
        let isRepeating = descriptor.atIndex(8)?.booleanValue ?? false
        let volumePercentage = descriptor.atIndex(9)?.int32Value ?? 50
        let artworkURL = descriptor.atIndex(10)?.stringValue ?? ""
        let trackID = Self.parseTrackID(descriptor.atIndex(11)?.stringValue)
        let isFavorite = await MainActor.run { self.prepareFavorite(for: trackID) }

        var state = PlaybackState(
            bundleIdentifier: "com.spotify.client",
            isPlaying: isPlaying,
            title: currentTrack,
            artist: currentTrackArtist,
            album: currentTrackAlbum,
            currentTime: currentTime,
            duration: duration,
            playbackRate: 1,
            isShuffled: isShuffled,
            repeatMode: isRepeating ? .all : .off,
            lastUpdated: Date(),
            artwork: nil,
            volume: Double(volumePercentage) / 100.0,
            isFavorite: isFavorite
        )

        if artworkURL == lastArtworkURL, let existingArtwork = self.playbackState.artwork {
            state.artwork = existingArtwork
        }

    playbackState = state

        if !artworkURL.isEmpty, let url = URL(string: artworkURL) {
            guard artworkURL != lastArtworkURL || state.artwork == nil else { return }
            artworkFetchTask?.cancel()

            let currentState = state

            artworkFetchTask = Task {
                do {
                    let data = try await ImageService.shared.fetchImageData(from: url)

                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        var updatedState = currentState
                        updatedState.artwork = data
                        // The liked state may have arrived while the artwork was downloading.
                        if self.favoriteTrackID == trackID {
                            updatedState.isFavorite = self.cachedFavorite
                        }
                        self.playbackState = updatedState
                        self.lastArtworkURL = artworkURL
                        self.artworkFetchTask = nil
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.artworkFetchTask = nil
                    }
                }
            }
        }
    }
    
    // MARK: - Favorites (Spotify Web API)

    func setFavorite(_ favorite: Bool) async {
        guard let trackID = await MainActor.run(body: { self.beginFavoriteChange(favorite) }) else {
            return
        }
        do {
            try await SpotifyLibraryAPI.setSaved(favorite, trackID: trackID)
        } catch {
            print("[SpotifyController] Failed to set favorite: \(error)")
            await MainActor.run {
                self.revertFavoriteChange(favorite, trackID: trackID)
                SpotifyAuthManager.shared.reportError(error.localizedDescription)
            }
        }
    }

    /// Records the current track and returns its liked state, fetching it from Spotify when the track changed.
    @MainActor
    private func prepareFavorite(for trackID: String?) -> Bool {
        currentTrackID = trackID

        guard let trackID, SpotifyAuthManager.shared.hasCredentials else {
            favoriteFetchTask?.cancel()
            favoriteTrackID = nil
            cachedFavorite = false
            return false
        }

        if favoriteTrackID != trackID {
            favoriteTrackID = trackID
            cachedFavorite = false
            favoriteFetchTask?.cancel()
            favoriteFetchTask = Task { [weak self] in
                do {
                    let saved = try await SpotifyLibraryAPI.isSaved(trackID: trackID)
                    await self?.applyFetchedFavorite(saved, for: trackID)
                } catch {
                    print("[SpotifyController] Failed to read favorite: \(error)")
                    SpotifyAuthManager.shared.reportError(error.localizedDescription)
                }
            }
        }
        return cachedFavorite
    }

    @MainActor
    private func applyFetchedFavorite(_ saved: Bool, for trackID: String) {
        guard favoriteTrackID == trackID else { return }
        cachedFavorite = saved
        var updated = playbackState
        updated.isFavorite = saved
        playbackState = updated
    }

    /// Optimistically flips the heart. Returns the track to send to Spotify, or nil if there is nothing to like.
    @MainActor
    private func beginFavoriteChange(_ favorite: Bool) -> String? {
        guard let trackID = currentTrackID, SpotifyAuthManager.shared.hasCredentials else { return nil }
        favoriteFetchTask?.cancel()
        favoriteTrackID = trackID
        applyFetchedFavorite(favorite, for: trackID)
        return trackID
    }

    @MainActor
    private func revertFavoriteChange(_ attempted: Bool, trackID: String) {
        applyFetchedFavorite(!attempted, for: trackID)
    }

    private static func parseTrackID(_ uri: String?) -> String? {
        let prefix = "spotify:track:"
        guard let uri, uri.hasPrefix(prefix) else { return nil }  // local files / podcasts can't be liked
        let id = String(uri.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

// MARK: - Private Methods

    private func executeCommand(_ command: String) async {
        let script = "tell application \"Spotify\" to \(command)"
        try? await AppleScriptHelper.executeVoid(script)
    }

    private func executeAndRefresh(_ command: String) async {
        await executeCommand(command)
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }
    
    private func fetchPlaybackInfoAsync() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Spotify"
            set isRunning to true
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackPosition to player position
                set trackDuration to duration of current track
                set shuffleState to shuffling
                set repeatState to repeating
                set currentVolume to sound volume
                set artworkURL to artwork url of current track
                set trackURI to id of current track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatState, currentVolume, artworkURL, trackURI}
            on error
                return {false, "Unknown", "Unknown", "Unknown", 0, 0, false, false, 50, "", ""}
            end try
        end tell
        """
        
        return try await AppleScriptHelper.execute(script)
    }
    
}
