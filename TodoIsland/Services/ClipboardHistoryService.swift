import AppKit
import Foundation
import os

/// Watches the general pasteboard and keeps the trailing seven usable
/// copies. Pure AppKit: 1 s changeCount polling, concealed-type payloads
/// (password managers) skipped, self-inflicted writes recognised and not
/// re-captured. History persists as JSON + image blobs in Application
/// Support so the panel survives relaunches.
@MainActor
final class ClipboardHistoryService {
  static let shared = ClipboardHistoryService()

  private static let log = Logger(
    subsystem: "com.fxl.TodoIsland", category: "clipboard"
  )

  private(set) var items: [ClipboardItem] = []
  var onItemsChanged: ([ClipboardItem]) -> Void = { _ in }

  private let pasteboard = NSPasteboard.general
  private var lastChangeCount = 0
  /// changeCounts produced by our own recopy() — skip them in poll().
  private var ownChangeCounts: Set<Int> = []
  private var timer: Timer?

  private var storeDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/TodoIsland/Clipboard")
  }
  private var indexURL: URL { storeDirectory.appendingPathComponent("history.json") }

  init() {
    lastChangeCount = pasteboard.changeCount
    loadPersisted()
  }

  func start() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.poll() }
    }
  }

  // MARK: - Capture

  func poll() {
    let count = pasteboard.changeCount
    guard count != lastChangeCount else { return }
    lastChangeCount = count
    guard !ownChangeCounts.contains(count) else { return }

    let typeNames = Set(pasteboard.types?.map(\.rawValue) ?? [])
    guard !ClipboardClassification.isConcealed(typeNames: typeNames) else { return }

    guard let item = capture(typeNames: typeNames) else { return }
    let next = ClipboardHistoryMath.insert(item, into: items)
    guard next != items else { return }
    items = next
    persist()
    onItemsChanged(items)
  }

  private func capture(typeNames: Set<String>) -> ClipboardItem? {
    let fileURLs = (pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL]) ?? []

    // Pasteboard TIFF for a Finder-copied image is a system thumbnail —
    // prefer PNG (full-size for web/screen copies), and treat image
    // FILES below by loading the original bytes straight from disk.
    let imageBytes =
      (typeNames.contains(NSPasteboard.PasteboardType.tiff.rawValue)
        || typeNames.contains(NSPasteboard.PasteboardType.png.rawValue))
      ? pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
      : nil

    let text =
      pasteboard.string(forType: .string)
      ?? (fileURLs.isEmpty ? nil : fileURLs.map(\.absoluteString).joined(separator: "\n"))

    guard
      let kind = ClipboardClassification.classify(
        typeNames: typeNames, fileURLs: fileURLs, imageBytes: imageBytes, text: text
      )
    else { return nil }

    // Image FILES: read the original bytes, not the thumbnail the
    // Finder preview put on the pasteboard.
    var resolvedImageData = imageBytes
    var sourceFileURL = kind == .video ? fileURLs.first : nil
    if kind == .image, imageBytes == nil || fileURLs.contains(where: {
      ClipboardClassification.imageExtensions.contains($0.pathExtension.lowercased())
    }) {
      let imageFile = fileURLs.first {
        ClipboardClassification.imageExtensions.contains($0.pathExtension.lowercased())
      }
      if let imageFile,
        let original = try? Data(contentsOf: imageFile),
        NSImage(data: original) != nil
      {
        resolvedImageData = original
        sourceFileURL = imageFile
      }
    }

    let id = UUID()
    if kind == .image, let resolvedImageData {
      blobPaths[id] = writeBlob(resolvedImageData)
    }

    return ClipboardItem(
      id: id,
      kind: kind,
      text: text,
      imageData: kind == .image ? resolvedImageData : nil,
      fileURL: sourceFileURL,
      capturedAt: Date(),
      contentHash: ClipboardHistoryService.contentHash(
        kind: kind, text: text, imageBytes: resolvedImageData, fileURLs: fileURLs
      )
    )
  }

  private static func contentHash(
    kind: ClipboardItem.Kind, text: String?, imageBytes: Data?, fileURLs: [URL]
  ) -> Int {
    var hasher = Hasher()
    hasher.combine(kind)
    switch kind {
    case .text: hasher.combine(text)
    case .image: hasher.combine(imageBytes?.count)
    case .video: hasher.combine(fileURLs.first?.absoluteString)
    }
    if let imageBytes, imageBytes.count <= 4_000_000 {
      hasher.combine(imageBytes)
    }
    return hasher.finalize()
  }

  // MARK: - Re-copy

  /// Puts the item back on the system pasteboard. The resulting
  /// changeCount is remembered so poll() doesn't swallow our own write.
  func recopy(_ item: ClipboardItem) {
    pasteboard.clearContents()
    switch item.kind {
    case .text:
      if let text = item.text {
        pasteboard.setString(text, forType: .string)
      }
    case .image:
      if let data = item.imageData {
        pasteboard.setData(data, forType: .tiff)
      }
    case .video:
      if let url = item.fileURL {
        pasteboard.writeObjects([url as NSURL])
      }
    }
    lastChangeCount = pasteboard.changeCount
    ownChangeCounts.insert(pasteboard.changeCount)
    Self.log.info("re-copied \(item.kind.rawValue, privacy: .public)")
  }

  // MARK: - Persistence (JSON index + image blobs)

  private struct PersistedItem: Codable {
    let id: UUID
    let kind: String
    let text: String?
    let blob: String?
    let fileURL: String?
    let capturedAt: Date
    let contentHash: Int
  }

  private func writeBlob(_ data: Data) -> String? {
    do {
      try FileManager.default.createDirectory(
        at: storeDirectory, withIntermediateDirectories: true)
      let name = "blob-\(UUID().uuidString).tiff"
      try data.write(to: storeDirectory.appendingPathComponent(name))
      return name
    } catch {
      Self.log.error("blob write failed: \(error.localizedDescription)")
      return nil
    }
  }

  private func persist() {
    let entries = items.map { item in
      PersistedItem(
        id: item.id,
        kind: item.kind.rawValue,
        text: item.text,
        blob: blobPaths[item.id],
        fileURL: item.fileURL?.absoluteString,
        capturedAt: item.capturedAt,
        contentHash: item.contentHash
      )
    }
    guard let data = try? JSONEncoder().encode(entries) else { return }
    do {
      try FileManager.default.createDirectory(
        at: storeDirectory, withIntermediateDirectories: true)
      try data.write(to: indexURL)
    } catch {
      Self.log.error("history persist failed: \(error.localizedDescription)")
    }
    pruneOrphanBlobs()
  }

  /// Blob file names by item id, tracked so persistence survives the
  /// runtime-only imageData.
  private var blobPaths: [UUID: String] = [:]

  private func loadPersisted() {
    guard
      let data = try? Data(contentsOf: indexURL),
      let entries = try? JSONDecoder().decode([PersistedItem].self, from: data)
    else { return }
    items = entries.compactMap { entry in
      guard let kind = ClipboardItem.Kind(rawValue: entry.kind) else { return nil }
      var imageData: Data?
      if let blob = entry.blob {
        imageData = try? Data(contentsOf: storeDirectory.appendingPathComponent(blob))
        blobPaths[entry.id] = blob
      }
      return ClipboardItem(
        id: entry.id,
        kind: kind,
        text: entry.text,
        imageData: imageData,
        fileURL: entry.fileURL.flatMap(URL.init(string:)),
        capturedAt: entry.capturedAt,
        contentHash: entry.contentHash
      )
    }
  }

  private func pruneOrphanBlobs() {
    let keep = Set(blobPaths.values)
    guard
      let names = try? FileManager.default.contentsOfDirectory(atPath: storeDirectory.path)
    else { return }
    for name in names where name.hasPrefix("blob-") && !keep.contains(name) {
      try? FileManager.default.removeItem(at: storeDirectory.appendingPathComponent(name))
    }
  }
}

