import Foundation
import GRDB
import SwiftUI
import os

enum LibraryViewMode: String, Codable, Sendable {
    case grid
    case list
}

enum SortOrder: String, Codable, CaseIterable, Sendable {
    case title
    case author
    case dateAdded
    case fileSize
    case format

    var displayName: String {
        switch self {
        case .title: "Title"
        case .author: "Author"
        case .dateAdded: "Date Added"
        case .fileSize: "File Size"
        case .format: "Format"
        }
    }

    var bookColumn: Book.Columns {
        switch self {
        case .title: .title
        case .author: .author
        case .dateAdded: .dateAdded
        case .fileSize: .fileSize
        case .format: .format
        }
    }
}

enum SidebarSelection: Hashable, Sendable {
    case library
    case recentlyOpened
    case watchedFolder(UUID)
    case collection(UUID)
}

@Observable
@MainActor
final class AppState {
    // MARK: - Library State

    var books: [Book] = []
    var watchedFolders: [WatchedFolder] = []
    var selectedBookIDs: Set<UUID> = []
    var quickLookBookID: UUID? = nil
    var viewMode: LibraryViewMode = .grid
    var sortOrder: SortOrder = .title
    var sortAscending: Bool = true
    var formatFilter: BookFormat? = nil
    var pageHapticFeedback: Bool = false
    /// 0.0 = very sensitive (threshold ~40), 1.0 = very resistant (threshold ~250). Default 0.5 (~145).
    var pageScrollResistance: Double = 0.5

    // MARK: - Appearance

    var readerTheme: ReaderTheme = .normal
    var readerFontSize: Double = 16 // pt, for reflowable content (10…36)
    var readerViewMode: ReaderViewMode = .singlePage

    // MARK: - Collections

    var collections: [Collection] = []
    var collectionGroups: [CollectionGroup] = []
    var collectionBookIDs: Set<UUID> = [] // book IDs for currently selected collection

    // MARK: - Sidebar

    var sidebarSelection: SidebarSelection? = .library

    // MARK: - Tabs

    var openTabs: [ReaderTab] = []
    var activeTabID: UUID? = nil // nil means the Library tab is active

    var activeTab: ReaderTab? {
        guard let activeTabID else { return nil }
        return openTabs.first { $0.id == activeTabID }
    }

    // MARK: - Scanning

    var isScanning: Bool = false
    var scanProgress: Double = 0

    // MARK: - Search

    var searchText: String = ""
    var ftsResults: [FullTextSearchManager.SearchResult] = []
    var isIndexing: Bool = false
    var indexingProgress: (done: Int, total: Int) = (0, 0)

    // MARK: - Model / Embedding State

    var isDownloadingModels: Bool = false
    var modelDownloadProgress: ModelDownloadManager.DownloadProgress?
    var embeddingModelReady: Bool = false
    var llmModelReady: Bool = false
    var isEmbeddingIndexing: Bool = false
    var embeddingIndexingProgress: (done: Int, total: Int) = (0, 0)

    // MARK: - Chat

    var showChatPanel: Bool = false
    var chatSession = ChatSession()

    /// True when the currently selected sidebar collection is flagged as a cookbook.
    var isCookbookModeActive: Bool {
        guard case .collection(let id) = sidebarSelection else { return false }
        return collections.first(where: { $0.id == id })?.isCookbook ?? false
    }

    // MARK: - Services (initialized in start())

    private(set) var repository: BookRepository!
    private(set) var collectionRepository: CollectionRepository!
    private(set) var annotationRepository: AnnotationRepository!
    private(set) var ftsManager: FullTextSearchManager!
    private(set) var modelDownloadManager: ModelDownloadManager!
    private(set) var llmEngine: LLMEngine!
    private(set) var embeddingManager: EmbeddingManager!
    private(set) var hybridSearchManager: HybridSearchManager!
    private(set) var chunkRepository: TextChunkRepository!
    private(set) var modelInfoRepository: ModelInfoRepository!
    private(set) var chatManager: ChatManager!
    let folderScanner = FolderScanner()
    let fileWatcher = FileWatcher()
    let metadataExtractor = MetadataExtractor()
    let thumbnailGenerator = ThumbnailGenerator()

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "EBookReader",
        category: "AppState"
    )
    private var bookObservation: AnyDatabaseCancellable?
    private var folderObservation: AnyDatabaseCancellable?
    private var collectionObservation: AnyDatabaseCancellable?
    private var groupObservation: AnyDatabaseCancellable?
    private var accessedFolderURLs: Set<URL> = []
    private var isShuttingDown = false

    init() {
        // Lightweight init: only restore UserDefaults. No file I/O, no DB access.
        if let modeString = UserDefaults.standard.string(forKey: "libraryViewMode"),
           let mode = LibraryViewMode(rawValue: modeString) {
            self.viewMode = mode
        }
        if let sortString = UserDefaults.standard.string(forKey: "sortOrder"),
           let sort = SortOrder(rawValue: sortString) {
            self.sortOrder = sort
        }
        self.sortAscending = UserDefaults.standard.object(forKey: "sortAscending") as? Bool ?? true
        self.pageHapticFeedback = UserDefaults.standard.bool(forKey: "pageHapticFeedback")
        if let r = UserDefaults.standard.object(forKey: "pageScrollResistance") as? Double {
            self.pageScrollResistance = r
        }
        if let t = UserDefaults.standard.string(forKey: "readerTheme"),
           let theme = ReaderTheme(rawValue: t) {
            self.readerTheme = theme
        }
        if let f = UserDefaults.standard.object(forKey: "readerFontSize") as? Double {
            self.readerFontSize = f
        }
        if let vm = UserDefaults.standard.string(forKey: "readerViewMode"),
           let mode = ReaderViewMode(rawValue: vm) {
            self.readerViewMode = mode
        }
    }

    // MARK: - Async Startup

    /// Call this from a .task modifier on the root view. Runs all heavy initialization
    /// off the main thread so the UI remains responsive.
    func start() async {
        // Initialize the database on a background thread to avoid blocking the main actor.
        let dbPool = await Task.detached(priority: .userInitiated) {
            // This runs off the main actor: directory creation + SQLite open + migrations.
            try? Constants.Directories.ensureDirectoriesExist()
            return DatabaseManager.shared.dbPool
        }.value

        repository = BookRepository(dbPool: dbPool)
        collectionRepository = CollectionRepository(dbPool: dbPool)
        annotationRepository = AnnotationRepository(dbPool: dbPool)
        ftsManager = FullTextSearchManager(dbPool: dbPool)

        // ML / embedding services
        chunkRepository = TextChunkRepository(dbPool: dbPool)
        modelInfoRepository = ModelInfoRepository(dbPool: dbPool)
        modelDownloadManager = ModelDownloadManager(dbPool: dbPool)
        llmEngine = LLMEngine()
        let posExtractor = PositionAwareTextExtractor()
        embeddingManager = EmbeddingManager(dbPool: dbPool, llmEngine: llmEngine, textExtractor: posExtractor)
        hybridSearchManager = HybridSearchManager(
            dbPool: dbPool,
            ftsManager: ftsManager,
            embeddingManager: embeddingManager,
            chunkRepository: chunkRepository
        )
        chatManager = ChatManager(hybridSearchManager: hybridSearchManager, llmEngine: llmEngine, chunkRepository: chunkRepository)

        startObservingDatabase()         // synchronous — @MainActor, no await needed
        await resolveAndWatchFolders()
        await restoreTabs()
        await startBackgroundIndexing()

        // Model download + embedding indexing + preload LLM (non-blocking)
        Task {
            await checkAndDownloadModels()
            // Preload generation model in background so chat is instant when opened
            Task.detached(priority: .background) { [weak self] in
                guard let self else { return }
                try? await self.llmEngine.preloadGenerationModel()
            }
        }
    }

    // MARK: - Database Observation

    private func startObservingDatabase() {
        restartBookObservation()

        let dbPool = repository.dbPool

        folderObservation = ValueObservation
            .tracking { db in
                try WatchedFolder.order(WatchedFolder.Columns.dateAdded.asc).fetchAll(db)
            }
            .start(in: dbPool, onError: { _ in }) { [weak self] folders in
                self?.watchedFolders = folders
            }

        collectionObservation = ValueObservation
            .tracking { db in
                try Collection.order(Collection.Columns.sortOrder.asc).fetchAll(db)
            }
            .start(in: dbPool, onError: { _ in }) { [weak self] collections in
                self?.collections = collections
            }

        groupObservation = ValueObservation
            .tracking { db in
                try CollectionGroup.order(CollectionGroup.Columns.sortOrder.asc).fetchAll(db)
            }
            .start(in: dbPool, onError: { _ in }) { [weak self] groups in
                self?.collectionGroups = groups
            }
    }

    /// (Re)starts book observation with the current sort settings.
    /// Call after changing sortOrder or sortAscending to update the live dataset.
    func restartBookObservation() {
        guard !isShuttingDown, repository != nil else { return }
        bookObservation?.cancel()
        let sortColumn = sortOrder.bookColumn
        let ascending = sortAscending
        let dbPool = repository.dbPool

        bookObservation = ValueObservation
            .tracking { db in
                try Book.order(ascending ? sortColumn.asc : sortColumn.desc).fetchAll(db)
            }
            .start(in: dbPool, onError: { _ in }) { [weak self] books in
                self?.books = books
            }
    }

    /// Cancels all database observations and marks the app as shutting down.
    /// Call before termination to prevent new observations from being started.
    func prepareForTermination() {
        isShuttingDown = true
        bookObservation?.cancel()
        folderObservation?.cancel()
        collectionObservation?.cancel()
        groupObservation?.cancel()
        bookObservation = nil
        folderObservation = nil
        collectionObservation = nil
        groupObservation = nil
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
    }

    // MARK: - Folder Management

    func addFolder(url: URL) async {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            let alreadyWatched = try await repository.watchedFolderExists(atPath: url.path)
            if alreadyWatched {
                // Folder already in library — rescan to pick up any changes
                // (new books, user-deleted books that should reappear, etc.)
                logger.info("Folder already watched, rescanning: \(url.path)")
                await scanFolder(url: url)
                return
            }

            let folder = WatchedFolder(path: url.path, bookmarkData: bookmarkData)
            try await repository.insertWatchedFolder(folder)

            fileWatcher.startWatching(path: url.path)

            await scanFolder(url: url)
        } catch {
            logger.error("Failed to add folder: \(error)")
        }
    }

    func addBooks(urls: [URL]) async {
        // Group files by parent directory
        var filesByFolder: [String: [URL]] = [:]
        for url in urls {
            let parentPath = url.deletingLastPathComponent().path
            filesByFolder[parentPath, default: []].append(url)
        }

        for (folderPath, fileURLs) in filesByFolder {
            // Check if this folder already exists as a full-import folder
            let existingFolder = try? await repository.fetchWatchedFolder(atPath: folderPath)
            if let existing = existingFolder, existing.isFullImport {
                // Full-import folder already covers these files — nothing to do
                continue
            }

            // Create partial-import folder entry if it doesn't exist
            if existingFolder == nil {
                let folder = WatchedFolder(
                    path: folderPath,
                    bookmarkData: Data(),
                    isFullImport: false
                )
                _ = try? await repository.insertWatchedFolder(folder)
            }

            // Import each selected file
            for url in fileURLs {
                let exists = (try? await repository.bookExists(atPath: url.path)) ?? false
                if exists { continue }

                guard let format = FileTypeDetector.detectFormat(from: url) else { continue }

                // Create per-file security-scoped bookmark
                let fileBookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )

                let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
                let fileSize = Int64(resourceValues?.fileSize ?? 0)
                let metadata = await metadataExtractor.extractMetadata(from: url, format: format)

                let bookId = UUID()
                var hasCachedThumbnail = false
                if let coverData = metadata.coverImageData {
                    hasCachedThumbnail = await thumbnailGenerator.saveCoverData(coverData, for: bookId)
                }

                let book = Book(
                    id: bookId,
                    filePath: url.path,
                    fileName: url.lastPathComponent,
                    title: metadata.title,
                    author: metadata.author,
                    format: format,
                    fileSize: fileSize,
                    pageCount: metadata.pageCount,
                    hasCachedThumbnail: hasCachedThumbnail,
                    bookmarkData: fileBookmark
                )
                _ = try? await repository.insertBook(book)
            }
        }

        // Index newly added books
        await indexNewBooks()
    }

    func removeFolder(_ folder: WatchedFolder) async {
        do {
            if folder.isFullImport {
                fileWatcher.stopWatching(path: folder.path)
            }
            try await repository.deleteBooksInFolder(folder.path)
            try await repository.deleteWatchedFolder(id: folder.id)
        } catch {
            logger.error("Failed to remove folder: \(error)")
        }
    }

    func scanFolder(url: URL) async {
        isScanning = true

        var buffer: [Book] = []
        buffer.reserveCapacity(100)

        for await info in await folderScanner.scan(folderURL: url) {
            let exists = (try? await repository.bookExists(atPath: info.url.path)) ?? false
            if exists { continue }

            let metadata = await metadataExtractor.extractMetadata(
                from: info.url,
                format: info.format
            )

            // Save cover to disk cache (not in the DB) and record the flag.
            let bookId = UUID()
            var hasCachedThumbnail = false
            if let coverData = metadata.coverImageData {
                hasCachedThumbnail = await thumbnailGenerator.saveCoverData(coverData, for: bookId)
            }

            let book = Book(
                id: bookId,
                filePath: info.url.path,
                fileName: info.fileName,
                title: metadata.title,
                author: metadata.author,
                format: info.format,
                fileSize: info.fileSize,
                pageCount: metadata.pageCount,
                language: metadata.language,
                publisher: metadata.publisher,
                isbn: metadata.isbn,
                bookDescription: metadata.description,
                hasCachedThumbnail: hasCachedThumbnail
            )
            buffer.append(book)

            if buffer.count >= 100 {
                try? await repository.insertBooks(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            try? await repository.insertBooks(buffer)
        }

        isScanning = false

        // Index newly scanned books
        await indexNewBooks()
    }

    // MARK: - Watched Folder Startup

    func resolveAndWatchFolders() async {
        let folders = (try? await repository.fetchAllWatchedFolders()) ?? []

        for folder in folders {
            if folder.isFullImport {
                // Try bookmark first; fall back to stored path (works without sandbox)
                let folderURL: URL
                if let url = folder.resolveBookmark() {
                    if url.startAccessingSecurityScopedResource() {
                        accessedFolderURLs.insert(url)
                    }
                    // Refresh stale bookmarks
                    if let newBookmarkData = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        try? await repository.updateWatchedFolderBookmark(
                            id: folder.id,
                            bookmarkData: newBookmarkData
                        )
                    }
                    folderURL = url
                } else {
                    // Bookmark invalid — use stored path directly (no sandbox restriction)
                    folderURL = URL(fileURLWithPath: folder.path)
                    logger.info("Bookmark stale for \(folder.path), using path directly")
                }

                guard FileManager.default.fileExists(atPath: folderURL.path) else {
                    logger.warning("Folder no longer exists: \(folderURL.path)")
                    continue
                }

                fileWatcher.startWatching(path: folderURL.path)
            } else {
                // Partial-import: resolve individual book bookmarks (optional with no sandbox)
                await resolveBookBookmarks(inFolder: folder.path)
            }
        }

        fileWatcher.setChangeHandler { [weak self] changedPaths in
            Task { @MainActor [weak self] in
                await self?.handleFileChanges(changedPaths)
            }
        }
    }

    private func resolveBookBookmarks(inFolder folderPath: String) async {
        let books = (try? await repository.fetchBooks(inFolder: folderPath)) ?? []
        for book in books {
            guard let url = book.resolveFileBookmark() else { continue }
            guard url.startAccessingSecurityScopedResource() else { continue }
            accessedFolderURLs.insert(url)
        }
    }

    /// Ensures the app has security-scoped access to a book's file.
    /// Retries bookmark resolution if needed. Returns true if the file is accessible.
    func ensureFileAccess(for book: Book) -> Bool {
        // Already accessible — fast path
        if FileManager.default.isReadableFile(atPath: book.filePath) {
            return true
        }

        // Try resolving the parent folder's bookmark
        let bookFolderPath = URL(fileURLWithPath: book.filePath).deletingLastPathComponent().path
        if let folder = watchedFolders.first(where: { bookFolderPath.hasPrefix($0.path) }),
           folder.isFullImport,
           let url = folder.resolveBookmark() {
            // Only call startAccessing if we haven't already (each call increments a ref count)
            if !accessedFolderURLs.contains(url), url.startAccessingSecurityScopedResource() {
                accessedFolderURLs.insert(url)
                // Refresh the bookmark for next launch
                if let newData = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    Task { try? await repository.updateWatchedFolderBookmark(id: folder.id, bookmarkData: newData) }
                }
            }
            if FileManager.default.isReadableFile(atPath: book.filePath) {
                return true
            }
        }

        // Try the book's own per-file bookmark (individual import)
        if let url = book.resolveFileBookmark(),
           !accessedFolderURLs.contains(url) {
            if url.startAccessingSecurityScopedResource() {
                accessedFolderURLs.insert(url)
                return true
            }
        }

        return false
    }

    func stopAccessingFolders() {
        for url in accessedFolderURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessedFolderURLs.removeAll()
        fileWatcher.stopAll()
    }

    // MARK: - File Change Handling

    private func handleFileChanges(_ paths: Set<String>) async {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileTypeDetector.isSupportedBookFile(url) else { continue }

            if FileManager.default.fileExists(atPath: path) {
                let exists = (try? await repository.bookExists(atPath: path)) ?? false
                if !exists { await importSingleBook(url: url) }
            } else {
                if let book = try? await repository.fetchBook(byPath: path) {
                    try? await repository.deleteBook(id: book.id)
                }
            }
        }
    }

    private func importSingleBook(url: URL) async {
        guard let format = FileTypeDetector.detectFormat(from: url) else { return }
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = Int64(resourceValues?.fileSize ?? 0)
        let metadata = await metadataExtractor.extractMetadata(from: url, format: format)

        let bookId = UUID()
        var hasCachedThumbnail = false
        if let coverData = metadata.coverImageData {
            hasCachedThumbnail = await thumbnailGenerator.saveCoverData(coverData, for: bookId)
        }

        let book = Book(
            id: bookId,
            filePath: url.path,
            fileName: url.lastPathComponent,
            title: metadata.title,
            author: metadata.author,
            format: format,
            fileSize: fileSize,
            pageCount: metadata.pageCount,
            hasCachedThumbnail: hasCachedThumbnail
        )
        _ = try? await repository.insertBook(book)

        // Index the new book
        await indexNewBooks()
    }

    /// Incrementally index any books not yet indexed (called after imports).
    private func indexNewBooks() async {
        guard !isIndexing else { return }
        let dbPool = repository.dbPool
        isIndexing = true
        await ftsManager.indexUnindexedBooks(from: dbPool) { [weak self] done, total in
            Task { @MainActor [weak self] in
                self?.indexingProgress = (done, total)
            }
        }
        isIndexing = false
    }

    // MARK: - Model Download & Embedding

    private func checkAndDownloadModels() async {
        await modelDownloadManager.ensureModelsRegistered()

        // Check current status
        let models = (try? await modelInfoRepository.fetchAll()) ?? []
        embeddingModelReady = models.first(where: { $0.id == Constants.Models.embeddingModelId })?.isReady ?? false
        llmModelReady = models.first(where: { $0.id == Constants.Models.llmModelId })?.isReady ?? false

        let pending = models.filter { !$0.isReady }
        guard !pending.isEmpty else {
            await loadLLMModel()
            await startEmbeddingIndexing()
            return
        }

        isDownloadingModels = true
        do {
            try await modelDownloadManager.downloadAllPendingModels { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.modelDownloadProgress = progress
                }
            }
        } catch {
            logger.error("Model download failed: \(error)")
        }
        isDownloadingModels = false

        embeddingModelReady = await modelDownloadManager.verifyModel(id: Constants.Models.embeddingModelId)
        llmModelReady = await modelDownloadManager.verifyModel(id: Constants.Models.llmModelId)

        await loadLLMModel()
        await startEmbeddingIndexing()
    }

    var llmLoadError: String?

    func loadLLMModel() async {
        guard llmModelReady else {
            llmLoadError = "LLM model not marked as ready"
            logger.warning("LLM model not ready, skipping load")
            return
        }
        guard let path = await modelDownloadManager.modelPath(id: Constants.Models.llmModelId) else {
            llmLoadError = "Model path not found in database"
            logger.error("LLM model path not found despite ready status")
            return
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            llmLoadError = "File missing at: \(path.path)"
            logger.error("LLM model file missing at: \(path.path)")
            return
        }
        if let attrs = try? fm.attributesOfItem(atPath: path.path),
           let size = attrs[.size] as? Int64 {
            logger.info("LLM model file: \(size) bytes at \(path.path)")
            if size < 1_000_000 {
                llmLoadError = "File too small (\(size) bytes) — corrupt download"
                return
            }
        }
        do {
            try await llmEngine.loadGenerationModel(path: path.path)
            llmLoadError = nil
            logger.info("LLM generation model loaded successfully")
        } catch {
            llmLoadError = "llama.cpp load failed: \(error)"
            logger.error("Failed to load LLM generation model: \(error)")
        }
    }

    private func startEmbeddingIndexing() async {
        guard embeddingModelReady, !isEmbeddingIndexing else { return }

        if let path = await modelDownloadManager.modelPath(id: Constants.Models.embeddingModelId) {
            do {
                try await llmEngine.loadEmbeddingModel(path: path.path)
            } catch {
                logger.error("Failed to load embedding model: \(error)")
                return
            }
        }

        isEmbeddingIndexing = true
        await embeddingManager.indexUnembeddedBooks(from: repository.dbPool) { [weak self] done, total in
            Task { @MainActor [weak self] in
                self?.embeddingIndexingProgress = (done, total)
            }
        }
        isEmbeddingIndexing = false
    }

    // MARK: - Tab Management

    func openBook(_ book: Book) {
        // Don't open books whose files are missing.
        guard book.isAvailable || ensureFileAccess(for: book) else {
            logger.warning("Cannot open book — file not found: \(book.filePath)")
            return
        }

        // If the book is already open, just activate its tab
        if let existing = openTabs.first(where: { $0.bookID == book.id }) {
            activeTabID = existing.id
            return
        }

        let tab = ReaderTab(bookID: book.id, bookTitle: book.displayTitle)
        openTabs.append(tab)
        activeTabID = tab.id

        // Update dateLastOpened
        Task {
            try? await repository.updateLastReadPosition(bookId: book.id, position: book.lastReadPosition ?? "")
        }

        persistTabs()
    }

    /// Removes a book from the library database. Does NOT delete the file on disk.
    /// If the book is open in a tab, that tab is closed first.
    /// Cleaning up thumbnail cache and FTS index as well.
    func deleteBook(_ book: Book) async {
        // Close tab if open
        if let tab = openTabs.first(where: { $0.bookID == book.id }) {
            closeTab(tab.id)
        }

        // Remove FTS index entries
        await ftsManager.removeIndex(for: book.id)

        // Remove embedding chunks
        await embeddingManager.removeIndex(for: book.id)

        // Remove from database (cascades to bookCollection, annotation, textChunk)
        try? await repository.deleteBook(id: book.id)

        // Remove thumbnail cache
        let thumbPath = Constants.Directories.thumbnailCache
            .appendingPathComponent("\(book.id.uuidString).jpg")
        try? FileManager.default.removeItem(at: thumbPath)

        logger.info("Deleted book from library: \(book.displayTitle)")
    }

    /// Removes multiple books from the library.
    func deleteBooks(_ bookIDs: Set<UUID>) async {
        for id in bookIDs {
            guard let book = books.first(where: { $0.id == id }) else { continue }
            await deleteBook(book)
        }
    }

    func closeTab(_ tabID: UUID) {
        guard let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }

        openTabs.remove(at: index)

        // Activate adjacent tab or fall back to library
        if activeTabID == tabID {
            if openTabs.isEmpty {
                activeTabID = nil
            } else {
                let newIndex = min(index, openTabs.count - 1)
                activeTabID = openTabs[newIndex].id
            }
        }

        persistTabs()
    }

    func activateTab(_ tabID: UUID) {
        activeTabID = tabID
        persistTabs()
    }

    func switchToLibrary() {
        activeTabID = nil
    }

    func selectNextTab() {
        guard !openTabs.isEmpty else { return }
        if let activeTabID, let index = openTabs.firstIndex(where: { $0.id == activeTabID }) {
            let nextIndex = (index + 1) % openTabs.count
            self.activeTabID = openTabs[nextIndex].id
        } else {
            activeTabID = openTabs.first?.id
        }
    }

    func selectPreviousTab() {
        guard !openTabs.isEmpty else { return }
        if let activeTabID, let index = openTabs.firstIndex(where: { $0.id == activeTabID }) {
            let prevIndex = index == 0 ? openTabs.count - 1 : index - 1
            self.activeTabID = openTabs[prevIndex].id
        } else {
            activeTabID = openTabs.last?.id
        }
    }

    func closeActiveTab() {
        if let activeTabID {
            closeTab(activeTabID)
        }
    }

    // MARK: - Tab Persistence

    private func persistTabs() {
        if let data = try? JSONEncoder().encode(openTabs) {
            UserDefaults.standard.set(data, forKey: "openTabs")
        }
        if let activeTabID {
            UserDefaults.standard.set(activeTabID.uuidString, forKey: "activeTabID")
        } else {
            UserDefaults.standard.removeObject(forKey: "activeTabID")
        }
    }

    func restoreTabs() async {
        guard let data = UserDefaults.standard.data(forKey: "openTabs"),
              let tabs = try? JSONDecoder().decode([ReaderTab].self, from: data) else {
            return
        }

        // Only restore tabs whose books still exist in the library
        var validTabs: [ReaderTab] = []
        for tab in tabs {
            if let book = try? await repository.fetchBook(id: tab.bookID), book.isAvailable {
                validTabs.append(tab)
            }
        }
        openTabs = validTabs

        if let idString = UserDefaults.standard.string(forKey: "activeTabID"),
           let id = UUID(uuidString: idString),
           openTabs.contains(where: { $0.id == id }) {
            activeTabID = id
        } else {
            activeTabID = nil
        }
    }

    // MARK: - Collection Management

    func createCollection(name: String, groupId: UUID? = nil) async {
        let sortOrder = (try? await collectionRepository.nextCollectionSortOrder(inGroup: groupId)) ?? 0
        let collection = Collection(name: name, collectionGroupId: groupId, sortOrder: sortOrder)
        _ = try? await collectionRepository.insertCollection(collection)
    }

    func renameCollection(id: UUID, name: String) async {
        guard var collection = collections.first(where: { $0.id == id }) else { return }
        collection.name = name
        try? await collectionRepository.updateCollection(collection)
    }

    func deleteCollection(id: UUID) async {
        try? await collectionRepository.deleteCollection(id: id)
        if case .collection(id) = sidebarSelection {
            sidebarSelection = .library
        }
    }

    func moveCollectionToGroup(collectionId: UUID, groupId: UUID?) async {
        try? await collectionRepository.moveCollection(id: collectionId, toGroup: groupId)
    }

    func addBooksToCollection(bookIDs: [UUID], collectionId: UUID) async {
        try? await collectionRepository.addBooks(bookIDs, toCollection: collectionId)
        // Refresh if this collection is currently selected
        if case .collection(collectionId) = sidebarSelection {
            await loadCollectionBooks(collectionId)
        }
    }

    func removeBookFromCollection(bookId: UUID, collectionId: UUID) async {
        try? await collectionRepository.removeBook(bookId, fromCollection: collectionId)
        if case .collection(collectionId) = sidebarSelection {
            await loadCollectionBooks(collectionId)
        }
    }

    func toggleCookbookType(collectionId: UUID) async {
        guard var collection = collections.first(where: { $0.id == collectionId }) else { return }
        collection.collectionType = collection.isCookbook ? "default" : "cookbook"
        try? await collectionRepository.updateCollection(collection)
    }

    func loadCollectionBooks(_ collectionId: UUID) async {
        let ids = (try? await collectionRepository.fetchBookIDs(inCollection: collectionId)) ?? []
        collectionBookIDs = Set(ids)
    }

    // MARK: - Collection Group Management

    func createCollectionGroup(name: String) async {
        let sortOrder = (try? await collectionRepository.nextGroupSortOrder()) ?? 0
        let group = CollectionGroup(name: name, sortOrder: sortOrder)
        _ = try? await collectionRepository.insertGroup(group)
    }

    func renameCollectionGroup(id: UUID, name: String) async {
        guard var group = collectionGroups.first(where: { $0.id == id }) else { return }
        group.name = name
        try? await collectionRepository.updateGroup(group)
    }

    func deleteCollectionGroup(id: UUID) async {
        try? await collectionRepository.deleteGroup(id: id)
    }

    // MARK: - Full-Text Search

    func startBackgroundIndexing() async {
        await indexNewBooks()
    }

    func performSearch(query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ftsResults = []
            return
        }
        if embeddingModelReady {
            // Hybrid search: FTS5 + vector reranking
            let hybridResults = await hybridSearchManager.search(query: query, books: books)
            ftsResults = hybridResults.map { hr in
                FullTextSearchManager.SearchResult(
                    id: hr.bookId,
                    title: hr.title,
                    author: hr.author,
                    format: hr.format,
                    snippet: hr.snippet,
                    rank: -hr.score // convert blended score to negative rank (FTS convention)
                )
            }
        } else {
            // Fallback to FTS-only
            ftsResults = await ftsManager.search(query: query, books: books)
        }
    }

    private var searchDebounceTask: Task<Void, Never>?

    func debouncedSearch(query: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    // MARK: - Chat

    func sendChatMessage(_ text: String) async {
        chatSession.isGenerating = true

        // Scope books by sidebar selection
        let scopedBooks: [Book]
        switch sidebarSelection {
        case .collection(let collectionId):
            scopedBooks = books.filter { book in
                collectionBookIDs.contains(book.id)
            }
        case .watchedFolder(let folderId):
            if let folder = watchedFolders.first(where: { $0.id == folderId }) {
                let folderPath = folder.path
                scopedBooks = books.filter { $0.filePath.hasPrefix(folderPath) }
            } else {
                scopedBooks = books
            }
        default:
            scopedBooks = books
        }

        // Try to load generation model on-demand if not loaded
        await loadLLMModel()

        // Pass debug info to chat manager
        await chatManager.setDebugInfo(llmLoadError)

        let history = chatSession.messages
        // Pass current book for summarization queries
        let currentBook: Book?
        if let activeTab, let book = books.first(where: { $0.id == activeTab.bookID }) {
            currentBook = book
        } else {
            currentBook = nil
        }

        let response = await chatManager.sendMessage(text, books: scopedBooks, history: history, currentBook: currentBook, isCookbookMode: isCookbookModeActive)
        chatSession.appendAssistantMessage(response.content, references: response.references)
        chatSession.isGenerating = false
    }

    // MARK: - Thumbnail Loading

    /// Loads a thumbnail for `book`, and if one is freshly generated (e.g. PDF first-page render)
    /// updates `hasCachedThumbnail` in the DB so subsequent launches skip re-generation.
    func loadThumbnail(for book: Book) async -> NSImage? {
        let image = await thumbnailGenerator.thumbnail(for: book)
        // If the book didn't previously have a cached thumbnail but we just got one,
        // persist the flag so the grid can optimise future placeholder decisions.
        if image != nil && !book.hasCachedThumbnail {
            try? await repository.markThumbnailCached(bookId: book.id)
        }
        return image
    }

    // MARK: - Theme / Font

    func cycleTheme() {
        let all = ReaderTheme.allCases
        let idx = all.firstIndex(of: readerTheme) ?? 0
        readerTheme = all[(idx + 1) % all.count]
        persistSettings()
    }

    func increaseFontSize() {
        readerFontSize = min(36, readerFontSize + 1)
        persistSettings()
    }

    func decreaseFontSize() {
        readerFontSize = max(10, readerFontSize - 1)
        persistSettings()
    }

    // MARK: - Settings Persistence

    func persistSettings() {
        UserDefaults.standard.set(viewMode.rawValue, forKey: "libraryViewMode")
        UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder")
        UserDefaults.standard.set(sortAscending, forKey: "sortAscending")
        UserDefaults.standard.set(pageHapticFeedback, forKey: "pageHapticFeedback")
        UserDefaults.standard.set(pageScrollResistance, forKey: "pageScrollResistance")
        UserDefaults.standard.set(readerTheme.rawValue, forKey: "readerTheme")
        UserDefaults.standard.set(readerFontSize, forKey: "readerFontSize")
        UserDefaults.standard.set(readerViewMode.rawValue, forKey: "readerViewMode")
        persistTabs()
    }

    /// Persists settings AND restarts observation with new sort order.
    /// Use this when sort settings change (not during shutdown).
    func persistSettingsAndResort() {
        persistSettings()
        restartBookObservation()
    }

    /// Cleanly shuts down LLM resources before app exit to prevent Metal crash.
    func shutdownLLM() {
        Task {
            await llmEngine?.shutdown()
        }
    }
}
