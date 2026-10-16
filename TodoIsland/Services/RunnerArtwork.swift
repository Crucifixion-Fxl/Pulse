import CryptoKit
import Foundation
import ImageIO

/// Complete skeleton loops rendered at >=60 samples/second, including the
/// upstream secondary motion. Playback needs neither a web view nor a network.
enum RunnerArtwork {
  struct Character: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let animation: String
    let duration: TimeInterval
    let frameCount: Int
    let frameWidth: Int
    let frameHeight: Int
    let columns: Int
    let sha256: String
  }

  struct Clip: @unchecked Sendable {
    let character: Character
    let frames: [CGImage]
  }

  private struct Manifest: Decodable { let characters: [Character] }
  enum Failure: Error { case invalidArtwork, missingArtwork }

  static let characters: [Character] = {
    guard let url = Bundle.main.url(forResource: "RunnerCharacters", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
      manifest.characters.count == 7 else { return [] }
    return manifest.characters
  }()

  /// Calendar weekday is Sunday=1, while the manifest begins on Monday.
  static func character(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> Character? {
    guard characters.count == 7 else { return nil }
    return characters[(calendar.component(.weekday, from: date) + 5) % 7]
  }

  static func nextDay(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
    calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
  }

  static func load(_ character: Character) throws -> Clip {
    guard let url = Bundle.main.url(forResource: "runner-\(character.id)", withExtension: "png") else {
      throw Failure.missingArtwork
    }
    return Clip(character: character, frames: try verifiedFrames(Data(contentsOf: url), character: character))
  }

  static func verifiedFrames(_ data: Data, character: Character) throws -> [CGImage] {
    guard data.count < 10_000_000,
      character.frameCount > 1, character.frameCount <= 240,
      character.duration > 0, character.duration <= 4,
      character.frameWidth == 128, character.frameHeight == 128, character.columns == 8,
      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == character.sha256,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
      sheet.width == character.columns * character.frameWidth,
      sheet.height == ((character.frameCount + character.columns - 1) / character.columns) * character.frameHeight
      else { throw Failure.invalidArtwork }
    return try (0..<character.frameCount).map { index in
      let width = character.frameWidth, height = character.frameHeight
      guard let frame = sheet.cropping(to: CGRect(x: (index % character.columns) * width,
        y: (index / character.columns) * height, width: width, height: height)),
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.invalidArtwork }
      context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
      guard let decoded = context.makeImage() else { throw Failure.invalidArtwork }
      return decoded
    }
  }
}
