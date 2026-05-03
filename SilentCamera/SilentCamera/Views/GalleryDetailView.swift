import Photos
import SwiftUI

struct GalleryDetailView: View {

    let asset: PHAsset
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                }
            }
            .navigationTitle("写真詳細")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }

                ToolbarItem(placement: .bottomBar) {
                    if let image {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("写真", image: Image(uiImage: image)))
                    }
                }
            }
            .alert("写真を削除", isPresented: $showDeleteConfirm) {
                Button("削除", role: .destructive) {
                    deletePhoto()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("この写真を削除しますか？この操作は取り消せません。")
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
        .task {
            let size = CGSize(
                width: UIScreen.main.bounds.width * UIScreen.main.scale,
                height: UIScreen.main.bounds.height * UIScreen.main.scale
            )
            image = await PhotoLibraryService.shared.requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFit
            )
        }
    }

    private func deletePhoto() {
        isDeleting = true
        Task {
            do {
                try await PhotoLibraryService.shared.deletePhotos([asset])
                onDelete()
                dismiss()
            } catch {
                isDeleting = false
                print("Delete failed: \(error)")
            }
        }
    }
}
