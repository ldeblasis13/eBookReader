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
    /// Folder scans and imports in flight; they can overlap (a rescan waits
    /// behind the launch reconcile), so `isScanning` follows a count.
    private var activeScans = 0

    private func beginScanning() {
        activeScans += 1
        isScanning = true
    }

    private func endScanning() {
        activeScans = max(0, activeScans - 1)
        isScanning = activeScans > 0
    }

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
    private(set) var recipeDetector: RecipeDetector!
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

    // Background task handles — kept so we can cancel them before LLM shutdown.
    private var startTask: Task<Void, Never>?
    private var backgroundStartupTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var embeddingTask: Task<Void, Never>?
    /// Fire-and-forget work that can reach the LLM (cookbook onboarding, recipe
    /// detection, chat sends). Each task removes itself when it finishes.
    private var trackedTasks: [UUID: Task<Void, Never>] = [:]

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
    ///
    /// Idempotent: `.task` runs again whenever a window appears — e.g. after the
    /// last window was closed and the user reopens one from the Dock — but the
    /// services (above all the single LLMEngine) must be created once per process.
    func start() async {
        if startTask == nil {
            startTask = Task { await self.performStart() }
        }
        await startTask?.value
    }

    private func performStart() async {
        // Initialize the database on a background thread to avoid blocking the main actor.
        let dbPool = await Task.detached(priority: .userInitiated) {
            // This runs off the main actor: directory creation + SQLite open + migrations.
            try? Constants.Directories.ensureDirectoriesExist()
            return DatabaseManager.shared.dbPool
        }.value

        // Quit arrived during the DB open: don't create an LLMEngine that
        // shutdownForTermination() has already passed by.
        guard !isShuttingDown else { return }

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
        recipeDetector = RecipeDetector(dbPool: dbPool)

        startObservingDatabase()         // synchronous — @MainActor, no await needed
        let watchedPaths = await resolveAndWatchFolders()
        // Watchers only see changes from now on. Pick up whatever changed
        // while the app was closed, in the background.
        enqueueLibraryUpdate { [weak self] in
            await self?.reconcileWatchedFolders(watchedPaths)
        }
        await restoreTabs()
        await startBackgroundIndexing()

        // Model download + embedding indexing + preload LLM (non-blocking).
        // Track the handle so we can cancel before LLM shutdown on quit.
        guard !isShuttingDown else { return }
        backgroundStartupTask = Task {
            await checkAndDownloadModels()
            guard !Task.isCancelled else { return }
            // Preload generation model in background so chat is instant when opened.
            preloadTask = Task.detached(priority: .background) { [weak self] in
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

            // Also brings back any of the folder's books the user had deleted
            // from the library: adding the folder again is asking for them.
            switch try await repository.registerFullImportFolder(path: url.path, bookmarkData: bookmarkData) {
            case .alreadyWatched:
                logger.info("Folder already watched, rescanning: \(url.path)")
            case .upgradedFromPartialImport:
                logger.info("Folder had books added one by one; now importing all of it: \(url.path)")
                fileWatcher.startWatching(path: url.path)
            case .added:
                fileWatcher.startWatching(path: url.path)
            }

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

        // Choosing a file explicitly brings it back if it was deleted from the library.
        try? await repository.clearExclusions(forPaths: urls.map(\.path))

        for (folderPath, fileURLs) in filesByFolder {
            // Check if this folder already exists as a full-import folder
            let existingFolder = try? await repository.fetchWatchedFolder(atPath: folderPath)
            if let existing = existingFolder, existing.isFullImport {
                // The folder's scan covers these files; import any that aren't
                // in the library (deleted earlier, or not seen yet).
                await importBooks(atPaths: fileURLs.map(\.path))
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
            // Inside another watched folder, its books would be imported
            // again by that folder's reconcile unless remembered as deleted.
            let insideAnotherFolder = await fullImportFolderPaths().contains {
                $0 != folder.path && folder.path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/")
            }
            try await repository.deleteBooksInFolder(folder.path, recordingExclusions: insideAnotherFolder)
            try await repository.deleteWatchedFolder(id: folder.id)
        } catch {
            logger.error("Failed to remove folder: \(error)")
        }
    }

    /// Brings the library in line with a folder's contents. A file that a
    /// missing book was moved or renamed to keeps that book's row (and its
    /// annotations); only files that match no book are imported.
    func scanFolder(url: URL) async {
        beginScanning()
        await enqueueLibraryUpdate { [weak self] in
            await self?.reconcileFolder(atPath: url.path)
        }.value
        endScanning()
    }

    // MARK: - Watched Folder Startup

    /// Starts watching every reachable full-import folder and returns the
    /// paths being watched, for the launch reconcile.
    @discardableResult
    func resolveAndWatchFolders() async -> [String] {
        let folders = (try? await repository.fetchAllWatchedFolders()) ?? []
        var reconcilablePaths: [String] = []

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

                // Books are stored under folder.path. If the bookmark now
                // resolves somewhere else the folder itself moved, and
                // diffing the new location against the old paths would be
                // meaningless — leave those rows for now.
                if folderURL.path == folder.path {
                    reconcilablePaths.append(folder.path)
                } else {
                    logger.warning("Watched folder moved to \(folderURL.path); not reconciling \(folder.path)")
                }
            } else {
                // Partial-import: resolve individual book bookmarks (optional with no sandbox)
                await resolveBookBookmarks(inFolder: folder.path)
            }
        }

        fileWatcher.setChangeHandler { [weak self] events in
            Task { @MainActor [weak self] in
                self?.enqueueLibraryUpdate { [weak self] in
                    await self?.handleFileChanges(events)
                }
            }
        }
        return reconcilablePaths
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

    /// Bumped when watched files go missing or come back, so views showing
    /// the missing-file warning re-check `Book.isAvailable` (that state lives
    /// on disk, not in the database, so nothing else would trigger a redraw).
    private(set) var fileAvailabilityRevision = 0

    /// `book.isAvailable`, re-evaluated whenever the file watcher sees a
    /// book file disappear or reappear. Use this from views.
    func isAvailable(_ book: Book) -> Bool {
        _ = fileAvailabilityRevision
        return book.isAvailable
    }

    // MARK: - Reconciling With Disk

    /// The tail of the queue of disk-driven library updates: file-watcher
    /// batches, the launch reconcile and folder rescans run one at a time,
    /// in order, so each plan sees the previous one's relocations and imports.
    private var libraryUpdateTail: Task<Void, Never>?

    @discardableResult
    private func enqueueLibraryUpdate(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = libraryUpdateTail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        libraryUpdateTail = task
        return task
    }

    /// Book rows are keyed by UUID, not path, and annotations, collections,
    /// reading position and embeddings cascade from them — so this never
    /// deletes. Renamed/moved files and folders keep their rows with updated
    /// paths; files that vanish stay in the library, flagged as missing.
    private func handleFileChanges(_ events: [FileEvent]) async {
        guard !isShuttingDown else { return }
        let plan = await BookRelocationPlanner.plan(
            for: events,
            repository: repository,
            watchedRoots: await fullImportFolderPaths()
        )
        await apply(plan)
    }

    /// Diffs the watched folders against the library, for changes made while
    /// the app wasn't running.
    private func reconcileWatchedFolders(_ folderPaths: [String]) async {
        for path in folderPaths {
            guard !isShuttingDown, !Task.isCancelled else { return }
            await reconcileFolder(atPath: path)
        }
    }

    private func reconcileFolder(atPath folderPath: String) async {
        guard !isShuttingDown else { return }
        let plan = await BookRelocationPlanner.plan(
            reconcilingFolder: folderPath,
            repository: repository,
            watchedRoots: await fullImportFolderPaths()
        )
        if plan != BookRelocationPlanner.Plan() {
            logger.info("""
                Reconciled \(folderPath): \(plan.relocations.count) moved, \
                \(plan.imports.count) new, \(plan.missing.count) missing
                """)
        }
        await apply(plan)
    }

    private func apply(_ plan: BookRelocationPlanner.Plan) async {
        let applied = await BookRelocationPlanner.applyRelocations(plan, repository: repository)
        for relocation in applied {
            logger.info("Book file moved, keeping library entry: \(relocation.newPath)")
        }
        if !plan.missing.isEmpty {
            logger.info("\(plan.missing.count) book file(s) missing; keeping library entries")
        }
        if !plan.missing.isEmpty || !plan.reappeared.isEmpty {
            fileAvailabilityRevision += 1
        }
        await importBooks(atPaths: plan.imports)
    }

    private func fullImportFolderPaths() async -> [String] {
        let folders = (try? await repository.fetchAllWatchedFolders()) ?? []
        return folders.filter(\.isFullImport).map(\.path)
    }

    /// Imports the book files at `paths` as new books, 100 per write.
    /// Skips paths that already have a row, files the user deleted from the
    /// library, files that are gone by now, and files outside every watched
    /// folder (the folder was removed meanwhile). Indexing the new books
    /// runs afterwards on its own task, so callers on the library-update
    /// queue don't hold it for a whole FTS pass.
    private func importBooks(atPaths paths: [String]) async {
        guard !paths.isEmpty else { return }
        beginScanning()

        let metadataExtractor = metadataExtractor
        let thumbnailGenerator = thumbnailGenerator
        var importedAny = false
        for start in stride(from: 0, to: paths.count, by: 100) {
            guard !isShuttingDown, !Task.isCancelled else { break }
            let chunk = Array(paths[start..<min(start + 100, paths.count)])
            let known = (try? await repository.existingBookPaths(among: chunk)) ?? []
            let excluded = (try? await repository.excludedPaths(among: chunk)) ?? []
            let roots = await fullImportFolderPaths().map { $0.hasSuffix("/") ? $0 : $0 + "/" }

            var books: [Book] = []
            for path in chunk
            where !known.contains(path) && !excluded.contains(path) && roots.contains(where: { path.hasPrefix($0) }) {
                guard !isShuttingDown, !Task.isCancelled else { break }
                if let book = await Self.makeBook(
                    forFileAt: URL(fileURLWithPath: path),
                    metadataExtractor: metadataExtractor,
                    thumbnailGenerator: thumbnailGenerator
                ) {
                    books.append(book)
                }
            }
            guard !books.isEmpty else { continue }
            do {
                try await repository.insertBooks(books)
                importedAny = true
            } catch {
                logger.error("Failed to save \(books.count) imported book(s): \(error)")
            }
        }

        endScanning()
        if importedAny {
            // Coalesces with a pass already running (indexingRequested).
            runTracked { [weak self] in
                await self?.indexNewBooks()
            }
        }
    }

    /// Reads a new book's metadata and caches its cover. Runs off the main
    /// actor; nil if the file is gone or isn't a supported book.
    nonisolated private static func makeBook(
        forFileAt url: URL,
        metadataExtractor: MetadataExtractor,
        thumbnailGenerator: ThumbnailGenerator
    ) async -> Book? {
        guard let format = FileTypeDetector.detectFormat(from: url),
              let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        let metadata = await metadataExtractor.extractMetadata(from: url, format: format)

        // Save cover to disk cache (not in the DB) and record the flag.
        let bookId = UUID()
        var hasCachedThumbnail = false
        if let coverData = metadata.coverImageData {
            hasCachedThumbnail = await thumbnailGenerator.saveCoverData(coverData, for: bookId)
        }

        return Book(
            id: bookId,
            filePath: url.path,
            fileName: url.lastPathComponent,
            title: metadata.title,
            author: metadata.author,
            format: format,
            fileSize: Int64(fileSize),
            pageCount: metadata.pageCount,
            language: metadata.language,
            publisher: metadata.publisher,
            isbn: metadata.isbn,
            bookDescription: metadata.description,
            hasCachedThumbnail: hasCachedThumbnail
        )
    }

    /// Set when books may need indexing while a pass is already running, so
    /// that pass goes round again instead of missing them.
    private var indexingRequested = false

    /// Incrementally index any books not yet indexed (called after imports).
    private func indexNewBooks() async {
        indexingRequested = true
        guard !isIndexing else { return }
        let dbPool = repository.dbPool
        isIndexing = true
        while indexingRequested, !isShuttingDown {
            indexingRequested = false
            await ftsManager.indexUnindexedBooks(from: dbPool) { [weak self] done, total in
                Task { @MainActor [weak self] in
                    self?.indexingProgress = (done, total)
                }
            }
        }
        isIndexing = false

        // FTS only made the books findable by keyword in book-level search.
        // For chat / cookbook mode we ALSO need embedding indexing to populate
        // the textChunk table. Previously embedding ran only at app startup,
        // so books imported afterwards were invisible to cookbook search
        // until the next launch. Kick it off in the background — guarded
        // internally against re-entry and missing model.
        //
        // Supersede rather than orphan an earlier pass: cancel it (it stops at
        // the next book boundary), let it unwind, then run a fresh pass that
        // also covers the books just imported. One handle then covers the
        // whole chain when shutdownForTermination() cancels it.
        guard !isShuttingDown else { return }
        let previous = embeddingTask
        previous?.cancel()
        embeddingTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.startEmbeddingIndexing()
        }
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

    /// Bookmarks set by recipe-card "Open" actions. The reader picks one up
    /// when it finishes loading the book and clears it. Keyed by book id so
    /// it survives across tab switches.
    private(set) var pendingJumpTargets: [UUID: ContentPosition] = [:]

    func openBook(_ book: Book) {
        openBook(book, jumpingTo: nil)
    }

    /// Opens a book (or activates its existing tab) and optionally schedules
    /// a jump to a specific position. Used by cookbook recipe cards so
    /// "Open" lands the user on the actual recipe page instead of the cover.
    func openBook(_ book: Book, jumpingTo position: ContentPosition?) {
        // Don't open books whose files are missing.
        guard book.isAvailable || ensureFileAccess(for: book) else {
            logger.warning("Cannot open book — file not found: \(book.filePath)")
            return
        }

        // Always record the pending jump (cleared by the reader once
        // navigation completes). This is what catches the cold-open case
        // where the reader hasn't subscribed to NotificationCenter yet.
        if let position { pendingJumpTargets[book.id] = position }

        // If the book is already open, just activate its tab AND fire the
        // navigation notification immediately — the reader is already
        // listening, so the post lands without needing the pending-jump
        // fallback.
        if let existing = openTabs.first(where: { $0.bookID == book.id }) {
            activeTabID = existing.id
            if let position {
                postNavigation(for: position)
            }
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

    /// The reader calls this once it has finished loading and is ready to
    /// accept navigation. Returns the queued position (if any) and clears
    /// it so a second tab activation doesn't re-jump.
    func consumePendingJump(forBook bookId: UUID) -> ContentPosition? {
        guard let pos = pendingJumpTargets.removeValue(forKey: bookId) else { return nil }
        return pos
    }

    /// Posts the format-appropriate navigation notification. Reader views
    /// (PDF, EPUB, FB2, web-based) already observe these for in-book
    /// search and TOC clicks — recipe cards just reuse the channel.
    private func postNavigation(for position: ContentPosition) {
        switch position {
        case .pdf(let pageIndex):
            NotificationCenter.default.post(
                name: .ebookReaderGoToPage,
                object: pageIndex
            )
        case .epub(let spineIndex, _):
            NotificationCenter.default.post(
                name: .ebookReaderNavigateToSpineIndex,
                object: spineIndex
            )
        case .fb2, .mobi, .chm:
            // Web-based readers don't expose a direct chunk anchor; the
            // reader will show the start of the document and the user
            // can use Find for the recipe title. Future work: wire an
            // anchor jump for these formats too.
            break
        }
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

        // Remove from database (cascades to bookCollection, annotation, textChunk).
        // The file is remembered as excluded, so reconciling its folder with
        // disk doesn't import it again; adding it or its folder explicitly does.
        try? await repository.deleteBookExcludingFile(book)

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

    // MARK: - Delete Confirmation

    /// A library deletion waiting for the user's confirmation; ContentView
    /// presents it. Deleting a book cascades to its annotations, collection
    /// memberships, reading position and embeddings, so menus call
    /// `requestDeleteBooks` / `requestRemoveFolder` rather than deleting directly.
    struct DeletionRequest: Identifiable {
        enum Target {
            case books(Set<UUID>)
            case folder(WatchedFolder)
        }

        let id = UUID()
        let target: Target
        let title: String
        let message: String
        let confirmTitle: String
    }

    var pendingDeletion: DeletionRequest?

    func requestDeleteBooks(_ bookIDs: Set<UUID>) async {
        guard !bookIDs.isEmpty else { return }
        let annotationCount = (try? await annotationRepository.annotationCount(forBooks: Array(bookIDs))) ?? 0
        let isSingle = bookIDs.count == 1
        let title: String
        if isSingle, let id = bookIDs.first {
            let name = books.first(where: { $0.id == id })?.displayTitle
            title = name.map { "Delete “\($0)” from Library?" } ?? "Delete 1 Book from Library?"
        } else {
            title = "Delete \(bookIDs.count.formatted()) Books from Library?"
        }
        let message = Self.deletionMessage(
            annotationCount: annotationCount,
            filesNote: isSingle ? "The book file stays on disk." : "The book files stay on disk."
        )
        pendingDeletion = DeletionRequest(
            target: .books(bookIDs),
            title: title,
            message: message,
            confirmTitle: isSingle ? "Delete from Library" : "Delete \(bookIDs.count.formatted()) Books"
        )
    }

    func requestRemoveFolder(_ folder: WatchedFolder) async {
        let bookCount = (try? await repository.countBooks(inFolder: folder.path)) ?? 0
        let annotationCount = (try? await annotationRepository.annotationCount(inFolder: folder.path)) ?? 0
        let books = bookCount == 1 ? "1 book" : "\(bookCount.formatted()) books"
        let message = "Its \(books) will be removed from your library. "
            + Self.deletionMessage(
                annotationCount: annotationCount,
                filesNote: "The folder and its files stay on disk."
            )
        pendingDeletion = DeletionRequest(
            target: .folder(folder),
            title: "Remove “\(folder.displayName)” from Library?",
            message: message,
            confirmTitle: "Remove Folder"
        )
    }

    func performDeletion(_ request: DeletionRequest) async {
        switch request.target {
        case .books(let bookIDs):
            await deleteBooks(bookIDs)
        case .folder(let folder):
            await removeFolder(folder)
        }
    }

    nonisolated static func deletionMessage(annotationCount: Int, filesNote: String) -> String {
        let annotations: String
        switch annotationCount {
        case 0: annotations = "No annotations will be lost."
        case 1: annotations = "1 annotation will be permanently deleted."
        default: annotations = "\(annotationCount.formatted()) annotations will be permanently deleted."
        }
        return "\(annotations) Reading positions and collection memberships are removed too. "
            + "This can't be undone. \(filesNote)"
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
        // If this is a cookbook collection, ensure its books are embedding-
        // indexed (recipe detection needs chunks to exist), THEN run the
        // detector. Without this, a fresh cookbook collection ends up
        // searchable but with zero text chunks until the next app launch.
        if let collection = collections.first(where: { $0.id == collectionId }), collection.isCookbook {
            scheduleCookbookIndexing(forBookIds: bookIDs)
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
        let willBeCookbook = !collection.isCookbook
        collection.collectionType = willBeCookbook ? "cookbook" : "default"
        try? await collectionRepository.updateCollection(collection)
        // If newly marked as cookbook, ensure all books in this collection
        // are embedding-indexed before running recipe detection.
        if willBeCookbook {
            let bookIds = (try? await collectionRepository.fetchBookIDs(inCollection: collectionId)) ?? []
            scheduleCookbookIndexing(forBookIds: bookIds)
        }
    }

    /// Indexing progress for the recipe detector (visible in cookbook collections).
    var recipeDetectionProgress: (done: Int, total: Int) = (0, 0)
    var isRecipeDetecting: Bool = false

    /// Background task — runs recipe detection in series for a set of books.
    /// Safe to call multiple times; each call enqueues a fresh detection pass.
    private func scheduleRecipeDetection(forBookIds bookIds: [UUID]) {
        guard !bookIds.isEmpty else { return }
        runTracked {
            self.isRecipeDetecting = true
            self.recipeDetectionProgress = (0, bookIds.count)
            for (i, bookId) in bookIds.enumerated() {
                if Task.isCancelled { break }
                await self.recipeDetector.detectRecipes(forBook: bookId)
                self.recipeDetectionProgress = (i + 1, bookIds.count)
            }
            self.isRecipeDetecting = false
            self.logger.info("Recipe detection complete for \(bookIds.count) books")
        }
    }

    /// User-triggered rebuild for a cookbook collection. Wipes the AI
    /// index (textChunk + recipeHint cascade) and FTS index for every book
    /// in the collection, resets the indexed flags, then re-runs the full
    /// pipeline. Use this when a collection is stuck in the "0 chunks"
    /// state because earlier indexing crashed silently.
    func rebuildCookbookIndex(collectionId: UUID) async {
        let bookIds = (try? await collectionRepository.fetchBookIDs(inCollection: collectionId)) ?? []
        guard !bookIds.isEmpty else {
            logger.info("Rebuild index: collection has no books")
            return
        }
        logger.info("Rebuild index: clearing \(bookIds.count) books in collection")

        // 1. Drop existing chunks + FTS rows + reset flags.
        for bookId in bookIds {
            try? await chunkRepository.deleteChunks(forBook: bookId)
            await ftsManager.removeIndex(for: bookId)
        }
        // Reset both flags via GRDB QueryInterface (raw .uuidString WHERE
        // would silently fail to match the BLOB-encoded id).
        try? await repository.dbPool.write { db in
            _ = try Book
                .filter(bookIds.contains(Book.Columns.id))
                .updateAll(
                    db,
                    Book.Columns.fullTextIndexed.set(to: false),
                    Book.Columns.embeddingIndexed.set(to: false)
                )
        }

        // 2. Re-run FTS + embedding + recipe detection.
        await indexNewBooks() // FTS pass — also kicks off embedding in background
        scheduleCookbookIndexing(forBookIds: bookIds)
    }

    /// Cookbook-onboarding pipeline: ensure every supplied book has been
    /// embedding-indexed (chunks inserted into textChunk + embeddings
    /// computed), THEN run recipe detection on the resulting chunks.
    /// Without this, recipe detection runs against an empty textChunk row
    /// set and the cookbook is silently empty until next launch.
    private func scheduleCookbookIndexing(forBookIds bookIds: [UUID]) {
        guard !bookIds.isEmpty else { return }
        runTracked { [weak self] in
            guard let self else { return }
            // 1. Find which books actually need embedding (skip already-indexed).
            let allBooks = (try? await self.repository.fetchBooks(byIds: bookIds)) ?? []
            let unembedded = allBooks.filter { !$0.embeddingIndexed }

            if !unembedded.isEmpty {
                self.logger.info("Cookbook onboarding: indexing \(unembedded.count) of \(bookIds.count) books")
                self.isEmbeddingIndexing = true
                var done = 0
                for book in unembedded {
                    if Task.isCancelled { break }
                    await self.embeddingManager.indexBook(book)
                    done += 1
                    self.embeddingIndexingProgress = (done, unembedded.count)
                }
                self.isEmbeddingIndexing = false
            }

            // 2. Now that chunks exist, run recipe detection.
            guard !Task.isCancelled else { return }
            self.scheduleRecipeDetection(forBookIds: bookIds)
        }
    }

    /// Runs `operation` in a Task that shutdownForTermination() cancels if it is
    /// still in flight. Refuses new work once shutdown has begun.
    private func runTracked(_ operation: @escaping @Sendable @MainActor () async -> Void) {
        guard !isShuttingDown else { return }
        let id = UUID()
        trackedTasks[id] = Task { [weak self] in
            await operation()
            self?.trackedTasks[id] = nil
        }
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

    /// Fire-and-forget entry point for the chat panel. Tracked so quitting
    /// mid-chat cancels the send instead of leaving it queued on the LLM.
    func submitChatMessage(_ text: String) {
        runTracked { [weak self] in
            await self?.sendChatMessage(text)
        }
    }

    func sendChatMessage(_ text: String) async {
        chatSession.isGenerating = true

        // Scope books by sidebar selection
        var scopedBooks: [Book]
        switch sidebarSelection {
        case .collection(let collectionId):
            // Refresh collection book IDs in case they're stale
            await loadCollectionBooks(collectionId)
            scopedBooks = books.filter { book in
                collectionBookIDs.contains(book.id)
            }
            logger.info("Chat scoped to collection: \(scopedBooks.count) books (collectionBookIDs: \(self.collectionBookIDs.count))")
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

        // Fallback: if scoped search would have zero books, use all books —
        // BUT cookbook mode never falls back outside its collection.
        if scopedBooks.isEmpty && !isCookbookModeActive {
            logger.warning("Scoped books empty, falling back to all \(self.books.count) books")
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
        chatSession.appendAssistantMessage(response)
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

    /// Gracefully shuts down the app in response to CMD-Q / Quit.
    ///
    /// Called by `AppDelegate.applicationShouldTerminate` which returns
    /// `.terminateLater` so AppKit blocks exit() until we reply.
    /// The critical path: cancel in-flight Tasks → await LLMEngine.shutdown()
    /// (which calls llama_backend_free and frees Metal resource sets) → reply.
    ///
    /// Without this, ggml's Metal resource sets are still alive when C++ static
    /// destructors run during exit(), causing `ggml_abort`.
    func shutdownForTermination() async {
        // 1. Persist state and cancel DB observations synchronously.
        persistSettings()
        stopAccessingFolders()
        prepareForTermination()

        // 2. Cancel all in-flight background tasks so they don't queue new
        //    llama.cpp work after we free the engine below. startTask is
        //    cancelled but kept, so a late start() can't build a second engine.
        startTask?.cancel()
        backgroundStartupTask?.cancel()
        preloadTask?.cancel()
        embeddingTask?.cancel()
        for task in trackedTasks.values { task.cancel() }
        libraryUpdateTail?.cancel()
        backgroundStartupTask = nil
        preloadTask = nil
        embeddingTask = nil
        trackedTasks.removeAll()

        // 3. Await full LLM / Metal shutdown.
        //    shutdown() flips the engine's stop flag first, so an in-flight
        //    generate() stops at its next token and anything queued behind it
        //    throws instead of reloading a model; then it frees models +
        //    llama_backend on the actor.
        await llmEngine?.shutdown()

        // 4. Allow AppKit to proceed with exit().
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
