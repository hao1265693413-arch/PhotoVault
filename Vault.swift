// PhotoVault - single-file build for GitHub Actions (iOS 16+)
// 由 merge.py 自动合并，请勿直接改这个文件。

// ===== Models.swift =====
import Foundation

struct Photo: Identifiable, Codable, Hashable {
    let id: UUID
    var filename: String
    var addedAt: Date
    var isFavorite: Bool
    var caption: String
    var albumName: String?
    /// 实况照片配对视频的文件名（没有则为 nil）
    var videoFilename: String?

    init(id: UUID = UUID(),
         filename: String,
         addedAt: Date = Date(),
         isFavorite: Bool = false,
         caption: String = "",
         albumName: String? = nil,
         videoFilename: String? = nil) {
        self.id = id
        self.filename = filename
        self.addedAt = addedAt
        self.isFavorite = isFavorite
        self.caption = caption
        self.albumName = albumName
        self.videoFilename = videoFilename
    }
}

struct Album: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

// ===== PhotoLibrary.swift =====
import Foundation
import Combine

/// 全部数据存在 Documents/library.json，照片文件在 Documents/VaultPhotos。
final class PhotoLibrary: ObservableObject {
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var albums: [Album] = []

    private struct Archive: Codable {
        var photos: [Photo]
        var albums: [Album]
    }

    private let storeURL: URL

    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storeURL = base.appendingPathComponent("library.json")
        load()
    }

    // MARK: - 读写

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(Archive.self, from: data) else { return }
        photos = archive.photos
        albums = archive.albums
    }

    private func save() {
        let archive = Archive(photos: photos, albums: albums)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(archive) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - 照片

    func addPhotos(items: [(filename: String, video: String?)], albumName: String?) {
        let newItems = items.map {
            Photo(filename: $0.filename, albumName: albumName, videoFilename: $0.video)
        }
        photos.insert(contentsOf: newItems, at: 0)
        save()
    }

    func delete(_ photo: Photo) {
        ImageStore.shared.delete(filename: photo.filename)
        if let video = photo.videoFilename {
            ImageStore.shared.delete(filename: video)
        }
        photos.removeAll { $0.id == photo.id }
        save()
    }

    func toggleFavorite(id: UUID) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].isFavorite.toggle()
        save()
    }

    func update(id: UUID, caption: String, albumName: String?) {
        guard let index = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[index].caption = caption
        photos[index].albumName = albumName
        save()
    }

    func photo(id: UUID) -> Photo? {
        photos.first { $0.id == id }
    }

    func count(inAlbum name: String) -> Int {
        photos.filter { $0.albumName == name }.count
    }

    var favoriteCount: Int {
        photos.filter { $0.isFavorite }.count
    }

    // MARK: - 相簿

    @discardableResult
    func addAlbum(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !albums.contains(where: { $0.name == trimmed }) else { return false }
        albums.append(Album(name: trimmed))
        save()
        return true
    }

    /// 删除相簿：里面的照片退回未分类，不会被删掉
    func deleteAlbum(id: UUID) {
        guard let album = albums.first(where: { $0.id == id }) else { return }
        for index in photos.indices where photos[index].albumName == album.name {
            photos[index].albumName = nil
        }
        albums.removeAll { $0.id == id }
        save()
    }
}

// ===== ImageStore.swift =====
import Foundation
import UIKit
import ImageIO

/// 照片文件的落盘与缩略图缓存。全部存在 App 沙盒内，不上传任何服务器。
final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()

    private let cache = NSCache<NSString, UIImage>()
    private let thumbCache = NSCache<NSString, UIImage>()
    let folder: URL

    private init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("VaultPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        cache.countLimit = 60
        thumbCache.countLimit = 400
    }

    func url(for filename: String) -> URL {
        folder.appendingPathComponent(filename)
    }

    /// 存盘（顺带做一次 JPEG 压缩），返回文件名
    func save(data: Data, quality: CGFloat = 0.9) throws -> String {
        let name = UUID().uuidString + ".jpg"
        let payload: Data
        if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: quality) {
            payload = jpeg
        } else {
            payload = data
        }
        try payload.write(to: url(for: name), options: .atomic)
        return name
    }

    func delete(filename: String) {
        try? FileManager.default.removeItem(at: url(for: filename))
        cache.removeObject(forKey: filename as NSString)
        thumbCache.removeAllObjects()
    }

    func image(for filename: String) -> UIImage? {
        let key = filename as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let img = UIImage(contentsOfFile: url(for: filename).path) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    /// 网格用的降采样缩略图，避免把 4000px 大图读进内存
    func thumbnail(for filename: String, maxPixel: CGFloat) -> UIImage? {
        let key = "\(Int(maxPixel))-\(filename)" as NSString
        if let hit = thumbCache.object(forKey: key) { return hit }

        let fileURL = url(for: filename)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg)
        thumbCache.setObject(image, forKey: key)
        return image
    }

    func fileSize(for filename: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url(for: filename).path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func totalBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(Int64(0)) { partial, fileURL in
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + Int64(size)
        }
    }

    func clearCaches() {
        cache.removeAllObjects()
        thumbCache.removeAllObjects()
    }

    static func formatted(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// ===== Brand.swift =====
import UIKit

/// 作者头像（192×192 JPEG，base64 内嵌，避免依赖资源目录）
enum Brand {
    static let authorName = "豪 hao"
    static let contact = "hao1265693413"
    static let notice = "这个 App 只是自己写着玩的试验品，功能简陋，其实没什么实际用处。\n建议直接卸载，谢谢。"

    private static let avatarBase64 =
    "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAcFBQYFBAcGBgYIBwcICxILCwoKCxYPEA0SGhYbGhkWGRgcICgiHB4mHhgZIzAkJior" +
    "LS4tGyIyNTEsNSgsLSz/2wBDAQcICAsJCxULCxUsHRkdLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCwsLCws" +
    "LCwsLCwsLCz/wAARCADAAMADASIAAhEBAxEB/8QAHQABAAICAwEBAAAAAAAAAAAAAAYHBAUCAwgBCf/EAEEQAAIBAwMCBQIDBAgF" +
    "AwUAAAECAwAEEQUSIQYxBxMiQVFhcRQygQgjkaEkQlJicrHB8BUXM4LRFpKiJVNjc9L/xAAUAQEAAAAAAAAAAAAAAAAAAAAA/8QA" +
    "FBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AouR1/CgsgLBSvBJ424/L9MA+32NdZaMYTc2xTjL5GR9vYniut2iigEcc" +
    "pLsWXdk5x2zj5/09q+SK4k8nJcK2ArD8vue5+T796DmqBjOpLNIoJUMeD75PseM/qa5xFIY7ba7hcngqCFBPv9e/t9q5W9uJo4Ii" +
    "dqtIFfGFK8+38R34runkS0sCJIxsKnygzElHDH4/j8c0HVPe/g1LRoFDDagBweOzEfx5rRszOxZiST3JrlNM88rSSHLMcmuFApSl" +
    "ApSlApSlApSlApSlApSlArKs5QFaI4GeRnA5+9YtPeg2qBkibA9XLYGBzkZ/z/lXyV9oUOdvJJBXHPPP8xXG0ZJxh/8AqbvVkDAH" +
    "PP0xXJtyOjoVxyODwAff7/egII42ZIsOOC2GwR9s/wC/8q7EADhisZ35XYc5+Md844rp3EzDI3HHqIHBbvnj6V2SyPKqny2V2fDL" +
    "Gcnb/oe3+zQfTmQ+c+NzH0sUA7/3R7jk1w2SSELINzg/mzlcnJ/nwK5SlJIY/NOXLZ2r2HI/0+P9KyY1Sa3VCmSvPKn0+o4A59xQ" +
    "d0O1W8xUDlRjcXPAB5bnt3Bx/wCa02p3gvLsmPcsCemNCewraXs800aWULyMPKy5JGNg5BHPHH1qP0ClKUClKUClKUClKUClKUCl" +
    "KUClKUClKUGWpdohcxORJH/1DnBxkYP+QrNSL8VbecrKWwHCkDazDuv0Pvj3zXToV9HY6tEbgbrWT93OvsUIwf4Zz+lZU2ny6TqY" +
    "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"
    static let avatar: UIImage? = {
        guard let data = Data(base64Encoded: avatarBase64, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }()
}

// ===== AppLock.swift =====
import Foundation
import CryptoKit

/// App 内的 4 位密码：只保存 SHA256 摘要，原文不落盘
enum AppLock {
    private static let pinKey = "appLockPinHash"

    static var hasPIN: Bool {
        UserDefaults.standard.string(forKey: pinKey) != nil
    }

    static func setPIN(_ pin: String) {
        UserDefaults.standard.set(hash(pin), forKey: pinKey)
    }

    static func removePIN() {
        UserDefaults.standard.removeObject(forKey: pinKey)
    }

    static func verify(_ pin: String) -> Bool {
        guard let stored = UserDefaults.standard.string(forKey: pinKey) else { return true }
        return stored == hash(pin)
    }

    private static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// ===== LivePhoto.swift =====
import Foundation
import Photos
import UIKit

/// 把实况照片（Live Photo）配对的 .mov 也导进沙盒，之后可以长按播放。
enum LivePhotoImporter {

    static func requestAccess() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status == .authorized || status == .limited)
            }
        }
    }

    /// 返回保存后的视频文件名；不是实况照片或没有权限时返回 nil
    static func exportVideo(assetIdentifier: String, baseName: String) async -> String? {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        guard let asset = fetched.firstObject,
              asset.mediaSubtypes.contains(.photoLive) else { return nil }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: {
            $0.type == .pairedVideo || $0.type == .fullSizePairedVideo
        }) else { return nil }

        let filename = baseName + ".mov"
        let destination = ImageStore.shared.url(for: filename)
        try? FileManager.default.removeItem(at: destination)

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            PHAssetResourceManager.default().writeData(for: resource,
                                                       toFile: destination,
                                                       options: nil) { error in
                if error == nil && FileManager.default.fileExists(atPath: destination.path) {
                    continuation.resume(returning: filename)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// ===== Compat.swift =====
import SwiftUI

/// iOS 15 兼容的导航容器：内部用 NavigationView，iOS 16+ 表现与 NavigationStack 基本一致
struct NavStack<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        NavigationView {
            content
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

/// iOS 15 兼容的「标题 — 值」行（替代 iOS 16 的 LabeledContent）
struct InfoRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// ===== PhotoPickerSheet.swift =====
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct PickedPhoto {
    let data: Data
    let assetIdentifier: String?
}

/// PHPicker 包装（iOS 14+ 可用，替代只能在 iOS 16 用的 SwiftUI PhotosPicker）
struct PhotoPickerSheet: UIViewControllerRepresentable {
    var selectionLimit: Int = 50
    var onFinish: ([PickedPhoto]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: PHPhotoLibrary.shared())
        config.filter = .images
        config.selectionLimit = selectionLimit
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let parent: PhotoPickerSheet

        init(_ parent: PhotoPickerSheet) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard !results.isEmpty else {
                parent.onFinish([])
                return
            }

            let group = DispatchGroup()
            let lock = NSLock()
            var collected: [PickedPhoto] = []

            for result in results {
                group.enter()
                let identifier = result.assetIdentifier
                let provider = result.itemProvider

                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                        if let data = data {
                            lock.lock()
                            collected.append(PickedPhoto(data: data, assetIdentifier: identifier))
                            lock.unlock()
                        }
                        group.leave()
                    }
                } else {
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                self.parent.onFinish(collected)
            }
        }
    }
}

// ===== Biometrics.swift =====
import Foundation
import LocalAuthentication

enum Biometrics {
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// 返回 true 表示验证通过（或设备本身没有设置密码，无法验证时放行）
    static func authenticate(reason: String = "解锁你的照片保险箱") async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "使用密码"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return true
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

// ===== LockScreen.swift =====
import SwiftUI

struct LockScreen: View {
    var onUnlock: () -> Void

    @State private var pin = ""
    @State private var message = ""
    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                if let avatar = Brand.avatar {
                    Image(uiImage: avatar)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                        .padding(.bottom, 4)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text("照片保险箱")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                if AppLock.hasPIN {
                    pinContent
                } else {
                    deviceAuthButton
                }
            }
            .padding(.horizontal, 40)
        }
        .task {
            if !AppLock.hasPIN {
                await deviceUnlock()
            }
        }
    }

    // MARK: - 密码模式

    private var pinContent: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < pin.count ? Color.white : Color.white.opacity(0.22))
                        .frame(width: 12, height: 12)
                }
            }
            .padding(.top, 6)

            Text(message.isEmpty ? "输入 4 位密码" : message)
                .font(.footnote)
                .foregroundStyle(message.isEmpty ? Color.white.opacity(0.55) : Color.red.opacity(0.9))

            VStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 22) {
                        ForEach(0..<3, id: \.self) { col in
                            keyButton(key(at: row, col: col))
                        }
                    }
                }
            }

            if Biometrics.isAvailable {
                Button {
                    Task { await deviceUnlock() }
                } label: {
                    Label("使用面容 ID", systemImage: "faceid")
                        .font(.footnote)
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.top, 2)
            }
        }
    }

    private func key(at row: Int, col: Int) -> String {
        let table = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "delete"]]
        return table[row][col]
    }

    @ViewBuilder
    private func keyButton(_ key: String) -> some View {
        if key.isEmpty {
            Color.clear.frame(width: 62, height: 62)
        } else if key == "delete" {
            Button {
                if !pin.isEmpty { pin.removeLast() }
            } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 62, height: 62)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                tap(key)
            } label: {
                Text(key)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func tap(_ key: String) {
        guard pin.count < 4 else { return }
        message = ""
        pin.append(key)
        guard pin.count == 4 else { return }

        if AppLock.verify(pin) {
            onUnlock()
        } else {
            message = "密码不正确"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pin = ""
            }
        }
    }

    // MARK: - 系统验证

    private var deviceAuthButton: some View {
        VStack(spacing: 12) {
            Text(message.isEmpty ? "点按下方按钮解锁" : message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))

            Button {
                Task { await deviceUnlock() }
            } label: {
                HStack(spacing: 8) {
                    if isAuthenticating {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "faceid")
                    }
                    Text(isAuthenticating ? "验证中…" : "解锁")
                }
                .font(.headline)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
            }
            .background(.white, in: Capsule())
            .foregroundStyle(.black)
            .disabled(isAuthenticating)
        }
    }

    private func deviceUnlock() async {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        let success = await Biometrics.authenticate()
        isAuthenticating = false
        if success {
            onUnlock()
        } else {
            message = "验证未通过，请再试一次"
        }
    }
}

// ===== RootView.swift =====
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("lockEnabled") private var lockEnabled = false
    @AppStorage("didShowNotice") private var didShowNotice = false

    @State private var isLocked = false
    @State private var didSetup = false
    @State private var showNotice = false

    var body: some View {
        ZStack {
            TabView {
                NavStack {
                    PhotoGridView()
                }
                .tabItem { Label("照片", systemImage: "photo.on.rectangle.angled") }

                NavStack {
                    AlbumsView()
                }
                .tabItem { Label("相簿", systemImage: "rectangle.stack") }

                NavStack {
                    SettingsView()
                }
                .tabItem { Label("设置", systemImage: "gearshape") }
            }

            if isLocked {
                LockScreen { isLocked = false }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear {
            guard !didSetup else { return }
            didSetup = true
            isLocked = lockEnabled
            if !didShowNotice {
                didShowNotice = true
                showNotice = true
            }
        }
        .sheet(isPresented: $showNotice) {
            NoticeView()
        }
        .onChange(of: scenePhase) { phase in
            guard lockEnabled else { return }
            if phase == .background {
                isLocked = true
            }
        }
    }
}


// MARK: - 首次启动说明

struct NoticeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            if let avatar = Brand.avatar {
                Image(uiImage: avatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 76, height: 76)
                    .clipShape(Circle())
                    .padding(.top, 24)
            }

            Text("说两句实话")
                .font(.title3.bold())

            Text(Brand.notice)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Text("知道了")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }
}

// ===== PhotoGridView.swift =====
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct PhotoGridView: View {
    let albumFilter: String?

    @EnvironmentObject private var library: PhotoLibrary

    @State private var showPicker = false
    @State private var isImporting = false
    @State private var searchText = ""
    @State private var favoritesOnly: Bool
    @State private var detail: DetailTarget?

    init(albumFilter: String? = nil, onlyFavorites: Bool = false) {
        self.albumFilter = albumFilter
        _favoritesOnly = State(initialValue: onlyFavorites)
    }

    private var photos: [Photo] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.photos.filter { photo in
            if let albumFilter, photo.albumName != albumFilter { return false }
            if favoritesOnly && !photo.isFavorite { return false }
            if keyword.isEmpty { return true }
            return photo.caption.localizedCaseInsensitiveContains(keyword)
                || (photo.albumName ?? "").localizedCaseInsensitiveContains(keyword)
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    Button {
                        detail = DetailTarget(index: index)
                    } label: {
                        PhotoThumb(photo: photo)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索备注或相簿")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showPicker = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    favoritesOnly.toggle()
                } label: {
                    Image(systemName: favoritesOnly ? "heart.fill" : "heart")
                }
                .foregroundColor(favoritesOnly ? .red : nil)
            }
        }
        .overlay {
            if photos.isEmpty && !isImporting {
                emptyState
            }
        }
        .overlay {
            if isImporting {
                importingOverlay
            }
        }
        .sheet(isPresented: $showPicker) {
            PhotoPickerSheet(selectionLimit: 50) { picked in
                showPicker = false
                guard !picked.isEmpty else { return }
                Task { await importPicked(picked) }
            }
        }
        .fullScreenCover(item: $detail) { target in
            PhotoDetailView(photos: photos, index: target.index)
        }
    }

    private var title: String {
        if favoritesOnly { return "收藏" }
        return albumFilter ?? "所有照片"
    }

    // MARK: - 导入

    private func importPicked(_ items: [PickedPhoto]) async {
        isImporting = true

        // 实况照片需要读取相册资源，没授权也不影响普通照片导入
        let canReadAssets = await LivePhotoImporter.requestAccess()
        var added: [(filename: String, video: String?)] = []

        for item in items {
            guard let filename = try? ImageStore.shared.save(data: item.data) else { continue }
            var videoName: String?
            if canReadAssets, let identifier = item.assetIdentifier {
                let baseName = (filename as NSString).deletingPathExtension
                videoName = await LivePhotoImporter.exportVideo(assetIdentifier: identifier,
                                                                baseName: baseName)
            }
            added.append((filename: filename, video: videoName))
        }

        library.addPhotos(items: added, albumName: albumFilter)
        isImporting = false
    }

    // MARK: - 空状态 / 进度

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tertiary)
            Text(favoritesOnly ? "还没有收藏" : "这里还是空的")
                .font(.headline)
            Text("从系统相册导入，照片会复制一份到 App 内部存储")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                showPicker = true
            } label: {
                Label("导入照片", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
    }

    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text("正在导入…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

struct DetailTarget: Identifiable {
    let id = UUID()
    let index: Int
}

// MARK: - 单格缩略图

struct PhotoThumb: View {
    let photo: Photo
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if photo.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .overlay(alignment: .topLeading) {
                if photo.videoFilename != nil {
                    Text("LIVE")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .clipped()
            .task(id: photo.filename) {
                let name = photo.filename
                let loaded = await Task.detached(priority: .userInitiated) {
                    ImageStore.shared.thumbnail(for: name, maxPixel: 340)
                }.value
                image = loaded
            }
    }
}

// ===== PhotoDetailView.swift =====
import SwiftUI
import UIKit
import Photos
import AVKit

struct PhotoDetailView: View {
    let photos: [Photo]
    @State private var index: Int

    @EnvironmentObject private var library: PhotoLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var showInfo = false
    @State private var toast: String?
    @State private var liveTarget: LiveTarget?

    init(photos: [Photo], index: Int) {
        self.photos = photos
        _index = State(initialValue: index)
    }

    private var current: Photo? {
        photos.indices.contains(index) ? photos[index] : nil
    }

    /// 实况视频地址（文件不存在就当作没有）
    private var currentVideoURL: URL? {
        guard let current, let fresh = library.photo(id: current.id),
              let video = fresh.videoFilename else { return nil }
        let url = ImageStore.shared.url(for: video)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 收藏状态从数据源读，保证点一下立刻变
    private var isFavorite: Bool {
        guard let current, let fresh = library.photo(id: current.id) else { return false }
        return fresh.isFavorite
    }

    var body: some View {
        NavStack {
            ZStack {
                Color.black.ignoresSafeArea()

                TabView(selection: $index) {
                    ForEach(photos.indices, id: \.self) { i in
                        ZoomablePhoto(photo: photos[i])
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()

                if let videoURL = currentVideoURL {
                    VStack {
                        Spacer()
                        Button {
                            liveTarget = LiveTarget(url: videoURL)
                        } label: {
                            Label("播放实况", systemImage: "livephoto.play")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.55), in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .padding(.bottom, 44)
                    }
                }

                if photos.count > 1 {
                    VStack {
                        Spacer()
                        Text("\(index + 1) / \(photos.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.bottom, 12)
                    }
                }

                if let toast {
                    VStack {
                        Spacer()
                        Text(toast)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(.bottom, 48)
                    }
                    .transition(.opacity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        if let current { library.toggleFavorite(id: current.id) }
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                    }

                    Menu {
                        Button {
                            saveToLibrary()
                        } label: {
                            Label("存回系统相册", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            showInfo = true
                        } label: {
                            Label("信息与备注", systemImage: "info.circle")
                        }
                        Divider()
                        Button(role: .destructive) {
                            deleteCurrent()
                        } label: {
                            Label("删除这张", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fullScreenCover(item: $liveTarget) { target in
                LivePlayerView(url: target.url)
            }
            .sheet(isPresented: $showInfo) {
                if let current {
                    PhotoInfoSheet(photoID: current.id)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - 操作

    private func deleteCurrent() {
        guard let current else { return }
        library.delete(current)
        dismiss()
    }

    private func saveToLibrary() {
        guard let current, let image = ImageStore.shared.image(for: current.filename) else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    showToast(success ? "已存回相册" : "保存失败")
                }
            }
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { toast = nil }
        }
    }
}

// MARK: - 可缩放的单张照片

struct ZoomablePhoto: View {
    let photo: Photo

    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnification)
                        .gesture(drag, including: scale > 1 ? .all : .subviews)
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.3)) {
                                if scale > 1 {
                                    resetZoom()
                                } else {
                                    scale = 2.5
                                    baseScale = 2.5
                                }
                            }
                        }
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: photo.filename) {
            let name = photo.filename
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageStore.shared.image(for: name)
            }.value
            image = loaded
        }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(baseScale * value, 1), 6)
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1 { resetZoom() }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: baseOffset.width + value.translation.width,
                                height: baseOffset.height + value.translation.height)
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}

// MARK: - 信息与备注

struct PhotoInfoSheet: View {
    let photoID: UUID

    @EnvironmentObject private var library: PhotoLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var caption = ""
    @State private var albumName = ""

    private var photo: Photo? { library.photo(id: photoID) }

    var body: some View {
        NavStack {
            Form {
                Section("备注") {
                    TextEditor(text: $caption)
                        .frame(minHeight: 76)
                }
                Section("归档") {
                    TextField("相簿名称（可留空）", text: $albumName)
                }
                if let photo {
                    Section("信息") {
                        InfoRow("加入时间",
                                photo.addedAt.formatted(date: .abbreviated, time: .shortened))
                        InfoRow("文件大小",
                                ImageStore.formatted(bytes: ImageStore.shared.fileSize(for: photo.filename)))
                        InfoRow("文件名", photo.filename)
                    }
                }
            }
            .navigationTitle("照片信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let trimmed = albumName.trimmingCharacters(in: .whitespacesAndNewlines)
                        library.update(id: photoID,
                                       caption: caption,
                                       albumName: trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let photo {
                    caption = photo.caption
                    albumName = photo.albumName ?? ""
                }
            }
        }
    }
}


// MARK: - 实况播放

struct LiveTarget: Identifiable {
    let id = UUID()
    let url: URL
}

struct LivePlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: AVPlayer(url: url))
                .ignoresSafeArea()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(16)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// ===== AlbumsView.swift =====
import SwiftUI

struct AlbumsView: View {
    @EnvironmentObject private var library: PhotoLibrary

    @State private var showNewAlbum = false
    @State private var newName = ""

    var body: some View {
        List {
            Section {
                NavigationLink {
                    PhotoGridView()
                } label: {
                    row(systemImage: "photo.on.rectangle.angled",
                        tint: .blue,
                        title: "所有照片",
                        count: library.photos.count)
                }

                NavigationLink {
                    PhotoGridView(onlyFavorites: true)
                } label: {
                    row(systemImage: "heart.fill",
                        tint: .pink,
                        title: "收藏",
                        count: library.favoriteCount)
                }
            }

            Section("我的相簿") {
                if library.albums.isEmpty {
                    Text("还没有相簿，点右上角 + 新建")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(library.albums) { album in
                    NavigationLink {
                        PhotoGridView(albumFilter: album.name)
                    } label: {
                        row(systemImage: "rectangle.stack.fill",
                            tint: .orange,
                            title: album.name,
                            count: library.count(inAlbum: album.name))
                    }
                }
                .onDelete(perform: deleteAlbums)
            }
        }
        .navigationTitle("相簿")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    newName = ""
                    showNewAlbum = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("新建相簿", isPresented: $showNewAlbum) {
            TextField("相簿名称", text: $newName)
            Button("取消", role: .cancel) { }
            Button("创建") {
                library.addAlbum(name: newName)
            }
        }
    }

    private func row(systemImage: String, tint: Color, title: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("\(count) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func deleteAlbums(_ offsets: IndexSet) {
        let ids = offsets.map { library.albums[$0].id }
        for id in ids {
            library.deleteAlbum(id: id)
        }
    }
}

// ===== SettingsView.swift =====
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var library: PhotoLibrary

    @AppStorage("lockEnabled") private var lockEnabled = false
    @State private var storageBytes: Int64 = 0
    @State private var showClearConfirm = false
    @State private var showPIN = false
    @State private var copied = false
    @State private var pinVersion = 0          // 用于刷新“已设置/未设置”文案

    private var biometricName: String {
        Biometrics.isAvailable ? "面容 / 指纹" : "设备密码"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    if let avatar = Brand.avatar {
                        Image(uiImage: avatar)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 58, height: 58)
                            .clipShape(Circle())
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Brand.authorName)
                            .font(.headline)
                        Text(Brand.contact)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section {
                Toggle(isOn: $lockEnabled) {
                    Label("启动时上锁", systemImage: "lock.fill")
                }

                Button {
                    showPIN = true
                } label: {
                    HStack {
                        Label("应用密码", systemImage: "number.square")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(AppLock.hasPIN ? "已设置" : "未设置")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .id(pinVersion)

                Text("设置 4 位数字密码后，锁屏可以输入密码解锁；开了 Face ID 也可以直接刷脸。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("隐私")
            }

            Section("存储") {
                InfoRow("照片数量", "\(library.photos.count) 张")
                InfoRow("相簿数量", "\(library.albums.count) 个")
                InfoRow("占用空间", ImageStore.formatted(bytes: storageBytes))
                Button {
                    showClearConfirm = true
                } label: {
                    Label("清理缩略图缓存", systemImage: "arrow.clockwise")
                }
            }

            Section {
                InfoRow("作者", Brand.authorName)

                Button {
                    UIPasteboard.general.string = Brand.contact
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                } label: {
                    HStack {
                        Text("联系方式").foregroundStyle(.primary)
                        Spacer()
                        Text(Brand.contact)
                            .foregroundStyle(.secondary)
                        Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(copied ? .green : .accentColor)
                    }
                }

                InfoRow("版本", "1.0")

                Text(Brand.notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } header: {
                Text("关于")
            }
        }
        .navigationTitle("设置")
        .onAppear { refreshStorage() }
        .onChange(of: library.photos.count) { _ in refreshStorage() }
        .confirmationDialog("清理缓存不会删除照片", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清理", role: .destructive) {
                ImageStore.shared.clearCaches()
                refreshStorage()
            }
            Button("取消", role: .cancel) { }
        }
        .sheet(isPresented: $showPIN, onDismiss: { pinVersion += 1 }) {
            ChangePINView()
        }
    }

    private func refreshStorage() {
        storageBytes = ImageStore.shared.totalBytes()
    }
}

// MARK: - 设置 / 修改 / 关闭应用密码

struct ChangePINView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var first = ""
    @State private var second = ""
    @State private var error = ""
    @State private var hasPIN = AppLock.hasPIN

    var body: some View {
        NavStack {
            Form {
                Section {
                    SecureField("输入 4 位数字密码", text: $first)
                        .keyboardType(.numberPad)
                    SecureField("再输入一次", text: $second)
                        .keyboardType(.numberPad)
                } header: {
                    Text(hasPIN ? "修改密码" : "设置密码")
                } footer: {
                    Text(error.isEmpty ? "密码只保存在本机，加密后存储，忘记只能重装 App。" : error)
                        .foregroundStyle(error.isEmpty ? Color.secondary : Color.red)
                }

                if hasPIN {
                    Section {
                        Button("关闭密码", role: .destructive) {
                            AppLock.removePIN()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("应用密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        let a = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = second.trimmingCharacters(in: .whitespacesAndNewlines)
        guard a.count == 4, a.allSatisfy({ $0.isNumber }) else {
            error = "请输入 4 位数字"
            return
        }
        guard a == b else {
            error = "两次输入不一致"
            return
        }
        AppLock.setPIN(a)
        dismiss()
    }
}

// ===== VaultApp.swift =====
import SwiftUI

@main
struct VaultApp: App {
    @StateObject private var library = PhotoLibrary()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
        }
    }
}
