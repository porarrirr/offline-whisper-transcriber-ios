import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FileImporter: UIViewControllerRepresentable {
    @Binding var selectedURL: URL?
    @Binding var isPresented: Bool
    var onComplete: ((Result<URL, Error>) -> Void)?
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        var supportedTypes: [UTType] = [
            .audio,
            .mp3,
            .wav,
            .mpeg4Movie,
            .movie
        ]
        supportedTypes.append(contentsOf: ["m4a", "aac", "mp4", "mov", "quicktime"].compactMap {
            UTType(filenameExtension: $0)
        })
        
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FileImporter
        
        init(_ parent: FileImporter) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.selectedURL = url
            parent.isPresented = false
            parent.onComplete?(.success(url))
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.isPresented = false
        }
    }
}
