// Appended to a temporary copy of AppModel.swift by render-readme.py, so the
// demo can seed private published state without adding production-only hooks.
// It is never included in the app target and never fetches a real playlist.
extension AppModel {
  func seedReadmeMusic() {
    favoriteTracks = [
      "Quiet Orbit", "After the Rain", "Soft Focus", "Blue Hour",
      "Sunday Morning", "Paper Planes", "The Long Way Home",
    ].enumerated().map { index, title in
      FavoriteTrack(id: -100-index, name: title, artist: "Pulse Demo", duration: 180)
    }
    favoritesState = .loaded
  }
}
