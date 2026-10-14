import SwiftUI
import UniformTypeIdentifiers

/// Attaches the "Link a Folder…" and "Import Files…" pickers.
/// SwiftUI honours only one `.fileImporter` per view, so the two importers are attached to
/// different views (the content itself and a clear background view).
private struct MusicSourceImportersModifier: ViewModifier {
    @Binding var isPickingFolder: Bool
    @Binding var isImportingFiles: Bool

    @Environment(LibraryStore.self) private var library
    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPickingFolder,
                allowedContentTypes: [.folder]
            ) { result in
                handleFolderPick(result)
            }
            .background {
                Color.clear
                    .accessibilityHidden(true)
                    .fileImporter(
                        isPresented: $isImportingFiles,
                        allowedContentTypes: SupportedMedia.importableTypes,
                        allowsMultipleSelection: true
                    ) { result in
                        handleFileImport(result)
                    }
            }
    }

    private func handleFolderPick(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task { @MainActor in
                let existingIDs = Set(library.folders.map(\.id))
                await library.addFolder(url)
                if let added = library.folders.first(where: { !existingIDs.contains($0.id) }) {
                    router.showToast("Linked “\(added.displayName)”")
                }
            }
        case .failure(let error):
            if !Self.isUserCancellation(error) {
                library.lastErrorMessage = "Couldn’t link that folder. \(error.localizedDescription)"
            }
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            Task { @MainActor in
                let imported = await library.importFiles(urls)
                if imported > 0 {
                    router.showToast(imported == 1 ? "Imported 1 file" : "Imported \(imported) files")
                } else if library.lastErrorMessage == nil {
                    router.showToast("No playable files were imported")
                }
            }
        case .failure(let error):
            if !Self.isUserCancellation(error) {
                library.lastErrorMessage = "Couldn’t import those files. \(error.localizedDescription)"
            }
        }
    }

    private static func isUserCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}

extension View {
    /// Adds the folder-link and file-import pickers driven by the two bindings.
    @MainActor func musicSourceImporters(isPickingFolder: Binding<Bool>, isImportingFiles: Binding<Bool>) -> some View {
        modifier(MusicSourceImportersModifier(isPickingFolder: isPickingFolder, isImportingFiles: isImportingFiles))
    }
}
