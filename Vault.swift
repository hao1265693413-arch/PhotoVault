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

    init(id: UUID = UUID(),
         filename: String,
         addedAt: Date = Date(),
         isFavorite: Bool = false,
         caption: String = "",
         albumName: String? = nil) {
        self.id = id
        self.filename = filename
        self.addedAt = addedAt
        self.isFavorite = isFavorite
        self.caption = caption
        self.albumName = albumName
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

    func addPhotos(filenames: [String], albumName: String?) {
        let newItems = filenames.map { Photo(filename: $0, albumName: albumName) }
        photos.insert(contentsOf: newItems, at: 0)
        save()
    }

    func delete(_ photo: Photo) {
        ImageStore.shared.delete(filename: photo.filename)
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

/// 上锁时盖在整个 App 上面的一层
struct LockScreen: View {
    var onUnlock: () -> Void

    @State private var message = "点按下方按钮解锁"
    @State private var isAuthenticating = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)

                VStack(spacing: 6) {
                    Text("照片保险箱")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Button {
                    Task { await unlock() }
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
                .padding(.top, 4)
            }
        }
        .task { await unlock() }
    }

    private func unlock() async {
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

    @State private var isLocked = false
    @State private var didSetup = false

    var body: some View {
        ZStack {
            TabView {
                NavigationStack {
                    PhotoGridView()
                }
                .tabItem { Label("照片", systemImage: "photo.on.rectangle.angled") }

                NavigationStack {
                    AlbumsView()
                }
                .tabItem { Label("相簿", systemImage: "rectangle.stack") }

                NavigationStack {
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
        }
        .onChange(of: scenePhase) { phase in
            guard lockEnabled else { return }
            if phase == .background {
                isLocked = true
            }
        }
    }
}

// ===== PhotoGridView.swift =====
import SwiftUI
import UIKit
import PhotosUI

struct PhotoGridView: View {
    let albumFilter: String?

    @EnvironmentObject private var library: PhotoLibrary

    @State private var pickerItems: [PhotosPickerItem] = []
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
                PhotosPicker(selection: $pickerItems,
                             maxSelectionCount: 50,
                             matching: .images,
                             photoLibrary: .shared()) {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    favoritesOnly.toggle()
                } label: {
                    Image(systemName: favoritesOnly ? "heart.fill" : "heart")
                }
                .tint(favoritesOnly ? .red : nil)
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
        .onChange(of: pickerItems) { items in
            guard !items.isEmpty else { return }
            Task { await importPicked(items) }
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

    @MainActor
    private func importPicked(_ items: [PhotosPickerItem]) async {
        isImporting = true
        var filenames: [String] = []
        for item in items {
            do {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let filename = try ImageStore.shared.save(data: data)
                    filenames.append(filename)
                }
            } catch {
                print("导入失败: \(error)")
            }
        }
        library.addPhotos(filenames: filenames, albumName: albumFilter)
        pickerItems = []
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
            PhotosPicker(selection: $pickerItems,
                         maxSelectionCount: 50,
                         matching: .images,
                         photoLibrary: .shared()) {
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

struct PhotoDetailView: View {
    let photos: [Photo]
    @State private var index: Int

    @EnvironmentObject private var library: PhotoLibrary
    @Environment(\.dismiss) private var dismiss

    @State private var showInfo = false
    @State private var toast: String?

    init(photos: [Photo], index: Int) {
        self.photos = photos
        _index = State(initialValue: index)
    }

    private var current: Photo? {
        photos.indices.contains(index) ? photos[index] : nil
    }

    /// 收藏状态从数据源读，保证点一下立刻变
    private var isFavorite: Bool {
        guard let current, let fresh = library.photo(id: current.id) else { return false }
        return fresh.isFavorite
    }

    var body: some View {
        NavigationStack {
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
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(.black.opacity(0.7), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
            .sheet(isPresented: $showInfo) {
                if let current {
                    PhotoInfoSheet(photoID: current.id)
                        .presentationDetents([.medium, .large])
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
        NavigationStack {
            Form {
                Section("备注") {
                    TextField("给这张照片加一句说明", text: $caption, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section("归档") {
                    TextField("相簿名称（可留空）", text: $albumName)
                }
                if let photo {
                    Section("信息") {
                        LabeledContent("加入时间",
                                       value: photo.addedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("文件大小",
                                       value: ImageStore.formatted(bytes: ImageStore.shared.fileSize(for: photo.filename)))
                        LabeledContent("文件名", value: photo.filename)
                            .font(.caption)
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
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7))

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
    @State private var copied = false

    private var biometricName: String {
        Biometrics.isAvailable ? "面容 / 指纹" : "设备密码"
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $lockEnabled) {
                    Label("启动时上锁", systemImage: "lock.fill")
                }
                Text("开启后，切到后台再回来或重新打开 App 需要验证\(biometricName)才能查看照片。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("隐私")
            }

            Section("存储") {
                LabeledContent("照片数量", value: "\(library.photos.count) 张")
                LabeledContent("相簿数量", value: "\(library.albums.count) 个")
                LabeledContent("占用空间", value: ImageStore.formatted(bytes: storageBytes))
                Button {
                    showClearConfirm = true
                } label: {
                    Label("清理缩略图缓存", systemImage: "arrow.clockwise")
                }
            }

            Section {
                LabeledContent("作者", value: "豪 hao")

                Button {
                    UIPasteboard.general.string = "hao1265693413"
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation { copied = false }
                    }
                } label: {
                    HStack {
                        Text("联系方式").foregroundStyle(.primary)
                        Spacer()
                        Text("hao1265693413")
                            .foregroundStyle(.secondary)
                        Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundStyle(copied ? .green : .accentColor)
                    }
                }

                LabeledContent("版本", value: "1.0")
            } header: {
                Text("关于")
            } footer: {
                Text("照片保险箱 · 由 豪 hao 制作。\n所有照片只保存在这台设备上，不上传服务器。卸载 App 会一起删除，建议定期用「存回系统相册」备份重要的照片。")
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
    }

    private func refreshStorage() {
        storageBytes = ImageStore.shared.totalBytes()
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
