import CryptoKit
import Foundation
import ImageIO

/// Upstream artwork remains upstream; the app caches a pinned, verified sheet
/// locally instead of redistributing artwork under the code's MIT license.
enum RunnerArtwork {
  static let revision = "85896750a3e4198c278e443efe77e58142aa9709"
  static let digest = "0136013a773feeeca74e0fc4653c4892d1ae2ccec219649af6e62cb54072a252"
  static let source = URL(string: "https://raw.githubusercontent.com/TonyNa-code/desktop-pet/\(revision)/assets/characters/default/preview.png")!
  static let frameCount = 8
  static let frameInterval: TimeInterval = 0.1

  enum Failure: Error { case invalidArtwork, downloadFailed }

  static var cacheURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("TodoIsland/CharacterAssets/\(digest).png")
  }

  static func load() async throws -> [CGImage] {
    let file = cacheURL
    if let data = try? Data(contentsOf: file), let frames = try? verifiedFrames(data) {
      return frames
    }
    let request = URLRequest(url: source, timeoutInterval: 20)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.downloadFailed }
    let frames = try verifiedFrames(data)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
    return frames
  }

  static func verifiedFrames(_ data: Data) throws -> [CGImage] {
    guard data.count < 2_000_000,
      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == digest,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
      sheet.width == 768, sheet.height == 832 else { throw Failure.invalidArtwork }
    return try runningFrames(in: sheet)
  }

  /// The preview uses the same 8x8 atlas as sprite.png, at 1/8 resolution.
  /// Its 96x104 frames still exceed the header's Retina rendering size.
  static func runningFrames(in sheet: CGImage) throws -> [CGImage] {
    guard sheet.width == 768, sheet.height == 832 else { throw Failure.invalidArtwork }
    return try (0..<frameCount).map { column in
      guard let frame = sheet.cropping(to: CGRect(x: column * 96, y: 104, width: 96, height: 104)),
        let context = CGContext(data: nil, width: 96, height: 104, bitsPerComponent: 8,
          bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.invalidArtwork }
      // Decode once off the main thread, not while the island is opening.
      context.draw(frame, in: CGRect(x: 0, y: 0, width: 96, height: 104))
      guard let decoded = context.makeImage() else { throw Failure.invalidArtwork }
      return decoded
    }
  }
}
