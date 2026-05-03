import AVKit
import Photos
import SwiftUI

enum MediaTypeFilter: String, CaseIterable, Identifiable {
    case all
    case photo
    case video

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "すべて"
        case .photo: return "写真"
        case .video: return "動画"
        }
    }
}

struct GalleryView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var assets: [PHAsset] = []
    @State private var selectedAsset: PHAsset?
    @State private var isDeleting = false
    @State private var showDeleteConfirm = false
    @State private var selectedAssets: Set<String> = []
    @State private var isEditMode = false
    @State private var mediaFilter: MediaTypeFilter = .all
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []

    private let columns = [
        GridItem(.adaptive(minimum: 100), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if assets.isEmpty {
                    ContentUnavailableView(
                        "写真がありません",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("カメラで写真を撮影するとここに表示されます")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(assets, id: \.localIdentifier) { asset in
                                GalleryThumbnailView(asset: asset)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipped()
                                    .overlay {
                                        if asset.mediaType == .video {
                                            videoBadge(duration: asset.duration)
                                        }
                                    }
                                    .overlay {
                                        if isEditMode {
                                            overlayCheckmark(for: asset)
                                        }
                                    }
                                    .onTapGesture {
                                        if isEditMode {
                                            toggleSelection(asset)
                                        } else {
                                            selectedAsset = asset
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .navigationTitle(isEditMode ? "\(selectedAssets.count)件選択" : "ギャラリー")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isEditMode ? "キャンセル" : "閉じる") {
                        if isEditMode {
                            isEditMode = false
                            selectedAssets.removeAll()
                        } else {
                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if !assets.isEmpty {
                        HStack {
                            if isEditMode && !selectedAssets.isEmpty {
                                Button("共有") {
                                    shareSelected()
                                }
                            }
                            Button(isEditMode ? "削除" : "選択") {
                                if isEditMode {
                                    if !selectedAssets.isEmpty {
                                        showDeleteConfirm = true
                                    }
                                } else {
                                    isEditMode = true
                                }
                            }
                            .foregroundStyle(isEditMode && !selectedAssets.isEmpty ? .red : .primary)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("メディア", selection: $mediaFilter) {
                        ForEach(MediaTypeFilter.allCases) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }
            .sheet(item: $selectedAsset) { asset in
                if asset.mediaType == .video {
                    VideoPlayerView(asset: asset)
                } else {
                    GalleryDetailView(asset: asset) {
                        loadAssets()
                    }
                }
            }
            .alert("写真を削除", isPresented: $showDeleteConfirm) {
                Button("削除", role: .destructive) {
                    deleteSelected()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("\(selectedAssets.count)件のメディアを削除しますか？この操作は取り消せません。")
            }
            .overlay {
                if isDeleting {
                    ProgressView("削除中...")
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .onAppear {
            loadAssets()
        }
        .onChange(of: mediaFilter) {
            loadAssets()
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
    }

    private func loadAssets() {
        switch mediaFilter {
        case .all:
            assets = PhotoLibraryService.shared.fetchRecentMedia(limit: 200)
        case .photo:
            assets = PhotoLibraryService.shared.fetchRecentPhotos(limit: 200)
        case .video:
            assets = PhotoLibraryService.shared.fetchRecentVideos(limit: 200)
        }
    }

    private func toggleSelection(_ asset: PHAsset) {
        if selectedAssets.contains(asset.localIdentifier) {
            selectedAssets.remove(asset.localIdentifier)
        } else {
            selectedAssets.insert(asset.localIdentifier)
        }
    }

    private func overlayCheckmark(for asset: PHAsset) -> some View {
        VStack {
            HStack {
                Spacer()
                Image(systemName: selectedAssets.contains(asset.localIdentifier) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedAssets.contains(asset.localIdentifier) ? .blue : .white.opacity(0.7))
                    .padding(6)
            }
            Spacer()
        }
    }

    private func videoBadge(duration: TimeInterval) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "video.fill")
                        .font(.caption2)
                    Text(formatDuration(duration))
                        .font(.caption2)
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6))
                .clipShape(Capsule())
                .padding(4)
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func deleteSelected() {
        let toDelete = assets.filter { selectedAssets.contains($0.localIdentifier) }
        isDeleting = true

        Task {
            do {
                try await PhotoLibraryService.shared.deletePhotos(toDelete)
                loadAssets()
                selectedAssets.removeAll()
                isEditMode = false
            } catch {
                print("Delete failed: \(error)")
            }
            isDeleting = false
        }
    }
    
    private func shareSelected() {
        let selectedAssetsList = assets.filter { selectedAssets.contains($0.localIdentifier) }
        shareItems = []
        
        Task {
            for asset in selectedAssetsList {
                if let image = await PhotoLibraryService.shared.requestImage(for: asset, targetSize: CGSize(width: 1024, height: 1024)) {
                    shareItems.append(image)
                }
            }
            if !shareItems.isEmpty {
                showShareSheet = true
            }
        }
    }
}

struct GalleryThumbnailView: View {

    let asset: PHAsset

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .overlay {
                        ProgressView()
                    }
            }
        }
        .task {
            let size = CGSize(width: 200, height: 200)
            image = await PhotoLibraryService.shared.requestImage(for: asset, targetSize: size)
        }
    }
}

struct VideoPlayerView: View {

    let asset: PHAsset

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                        .onAppear {
                            player.play()
                        }
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                }
            }
            .navigationTitle("動画")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") {
                        player?.pause()
                        dismiss()
                    }
                }
            }
        }
        .task {
            if let avAsset = await PhotoLibraryService.shared.requestAVAsset(for: asset) {
                await MainActor.run {
                    player = AVPlayer(playerItem: AVPlayerItem(asset: avAsset))
                    isLoading = false
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
