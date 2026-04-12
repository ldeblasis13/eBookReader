import AppKit
import PDFKit
import SwiftUI

// NSEvent is not yet annotated as Sendable in the Apple SDK. All local event-monitor
// callbacks are documented to run on the main thread, so wrapping in an @unchecked Sendable
// box is safe and is the standard bridging pattern for pre-concurrency AppKit types.
private struct NSEventTransfer: @unchecked Sendable { let event: NSEvent }

/// Displays the reader for a specific book, routing to the correct format viewer.
struct BookReaderView: View {
    @Environment(AppState.self) private var appState
    let book: Book

    // PDF state
    @State private var currentPage: Int = 0
    @State private var totalPages: Int = 0
    @State private var pdfDocument: PDFDocument?
    @State private var readerViewMode: ReaderViewMode = .singlePage

    // Web reader state (ePub / FB2 / Mobi / CHM)
    @State private var currentChapter: Int = 0
    @State private var totalChapters: Int = 0
    @State private var webPaginatedPage: Int = 0
    @State private var webPaginatedTotalPages: Int = 0
    @State private var epubContent: EPubParser.EPubContent?
    @State private var epubCombinedURL: URL?
    @State private var fb2Content: FB2Parser.FB2Content?
    @State private var mobiContent: MobiParser.MobiContent?
    @State private var chmContent: CHMParser.CHMContent?
    @State private var webReaderContent: WebReaderContent?

    // Shared state
    @State private var showTOC: Bool = false
    @State private var showSearchPanel: Bool = false
    @State private var searchState = InBookSearchState()
    @State private var annotationState = AnnotationState()

    var body: some View {
        HStack(spacing: 0) {
            if showTOC {
                tocSidebar
                    .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)
                Divider()
            }

            VStack(spacing: 0) {
                readerToolbar
                Divider()
                AnnotationToolbar(annotationState: annotationState, isPDF: book.format == .pdf)
                Divider()
                if showSearchPanel {
                    FindBar(searchState: searchState) {
                        showSearchPanel = false
                        searchState.clear()
                    }
                    Divider()
                }
                readerView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            if annotationState.showAnnotationList {
                Divider()
                AnnotationListView(
                    annotationState: annotationState,
                    bookId: book.id
                ) { annotation in
                    navigateToAnnotation(annotation)
                }
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 350)
                .frame(maxHeight: .infinity)
            }

            if showSearchPanel && !searchState.results.isEmpty {
                Divider()
                SearchResultsSidebar(searchState: searchState)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 350)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .ebookReaderToggleFindBar)) { _ in
            showSearchPanel.toggle()
            if !showSearchPanel { searchState.clear() }
        }
        .onKeyPress(.escape) {
            if showSearchPanel {
                showSearchPanel = false
                searchState.clear()
                return .handled
            }
            if annotationState.activeTool != nil {
                annotationState.deactivateTool()
                return .handled
            }
            return .ignored
        }
        .environment(searchState)
        .onAppear {
            readerViewMode = appState.readerViewMode
        }
        .onChange(of: readerViewMode) {
            appState.readerViewMode = readerViewMode
            appState.persistSettings()
            // View mode change is handled by the coordinator's applyViewMode() —
            // no content reload needed since the entire book is one document
        }
        .task {
            await loadAnnotations()
        }
        .sheet(isPresented: Binding(
            get: { annotationState.selectedAnnotationID != nil },
            set: { if !$0 { annotationState.selectedAnnotationID = nil } }
        )) {
            if let annotation = annotationState.selectedAnnotation {
                NoteEditorSheet(
                    annotation: annotation,
                    onSave: { note in
                        Task {
                            try? await appState.annotationRepository.updateNote(
                                id: annotation.id, note: note
                            )
                            let loaded = (try? await appState.annotationRepository.fetchAnnotations(forBook: book.id)) ?? []
                            annotationState.annotations = loaded
                            annotationState.selectedAnnotationID = nil
                            NotificationCenter.default.post(name: .ebookReaderRefreshAnnotations, object: nil)
                        }
                    },
                    onCancel: {
                        annotationState.selectedAnnotationID = nil
                    }
                )
            }
        }
    }

    private func loadAnnotations() async {
        let loaded = (try? await appState.annotationRepository.fetchAnnotations(forBook: book.id)) ?? []
        annotationState.annotations = loaded
    }

    private func navigateToAnnotation(_ annotation: Annotation) {
        guard let pos = annotation.decodedPosition else { return }
        switch pos {
        case .pdf(let pageIndex, _):
            NotificationCenter.default.post(
                name: .ebookReaderGoToPage,
                object: pageIndex
            )
        case .reflowable(let chapterIndex, _, _, _, _, _):
            // For reflowable, navigate to the chapter
            if book.format == .epub, let epubContent {
                let spineIndex = min(chapterIndex, epubContent.spine.count - 1)
                NotificationCenter.default.post(
                    name: .ebookReaderNavigateToSpineIndex,
                    object: spineIndex
                )
            }
        }
    }

    // MARK: - TOC Sidebar

    @ViewBuilder
    private var tocSidebar: some View {
        switch book.format {
        case .pdf:
            TableOfContentsView(
                outline: pdfDocument?.outlineRoot
            ) { destination in
                NotificationCenter.default.post(
                    name: .ebookReaderNavigateToDestination,
                    object: destination
                )
            }

        case .epub:
            if let epubContent, !epubContent.toc.isEmpty {
                WebTOCListView(items: epubContent.toc) { href in
                    navigateEPub(to: href)
                }
            } else {
                ContentUnavailableView(
                    "No Table of Contents",
                    systemImage: "list.bullet",
                    description: Text("This book does not have a table of contents.")
                )
            }

        case .fb2:
            if let fb2Content, !fb2Content.sections.isEmpty {
                FB2TOCListView(sections: fb2Content.sections) { anchor in
                    NotificationCenter.default.post(
                        name: .ebookReaderNavigateToWebContent,
                        object: WebNavigationTargetWrapper(.scrollToAnchor(anchor))
                    )
                }
            } else {
                ContentUnavailableView(
                    "No Table of Contents",
                    systemImage: "list.bullet",
                    description: Text("This book does not have a table of contents.")
                )
            }

        case .mobi, .azw3:
            if let mobiContent, !mobiContent.chapters.isEmpty {
                MobiTOCListView(chapters: mobiContent.chapters) { anchor in
                    NotificationCenter.default.post(
                        name: .ebookReaderNavigateToWebContent,
                        object: WebNavigationTargetWrapper(.scrollToAnchor(anchor))
                    )
                }
            } else {
                ContentUnavailableView(
                    "No Table of Contents",
                    systemImage: "list.bullet",
                    description: Text("This book does not have a table of contents.")
                )
            }

        case .chm:
            if let chmContent, !chmContent.sections.isEmpty {
                CHMTOCListView(sections: chmContent.sections) { path in
                    NotificationCenter.default.post(
                        name: .ebookReaderNavigateToWebContent,
                        object: WebNavigationTargetWrapper(.scrollToAnchor(path))
                    )
                }
            } else {
                ContentUnavailableView(
                    "No Table of Contents",
                    systemImage: "list.bullet",
                    description: Text("This book does not have a table of contents.")
                )
            }
        }
    }

    // MARK: - Reader View

    @ViewBuilder
    private var readerView: some View {
        switch book.format {
        case .pdf:
            PDFReaderViewWrapper(
                book: book,
                currentPage: $currentPage,
                totalPages: $totalPages,
                pdfDocument: $pdfDocument,
                viewMode: readerViewMode,
                annotationState: annotationState
            )

        case .epub:
            if let webReaderContent {
                EPubReaderWrapper(
                    book: book,
                    content: webReaderContent,
                    currentChapter: $currentChapter,
                    totalChapters: $totalChapters,
                    paginatedPage: $webPaginatedPage,
                    paginatedTotalPages: $webPaginatedTotalPages,
                    epubContent: epubContent,
                    viewMode: readerViewMode,
                    annotationState: annotationState
                )
            } else {
                ProgressView("Loading ePub...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await loadEPub() }
            }

        case .fb2:
            if let webReaderContent {
                FB2ReaderWrapper(
                    book: book,
                    content: webReaderContent,
                    currentChapter: $currentChapter,
                    totalChapters: $totalChapters,
                    paginatedPage: $webPaginatedPage,
                    paginatedTotalPages: $webPaginatedTotalPages,
                    viewMode: readerViewMode,
                    annotationState: annotationState
                )
            } else {
                ProgressView("Loading FB2...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await loadFB2() }
            }

        case .mobi, .azw3:
            if let webReaderContent {
                WebBasedReaderWrapper(
                    book: book,
                    content: webReaderContent,
                    currentChapter: $currentChapter,
                    totalChapters: $totalChapters,
                    paginatedPage: $webPaginatedPage,
                    paginatedTotalPages: $webPaginatedTotalPages,
                    viewMode: readerViewMode,
                    annotationState: annotationState
                )
            } else {
                ProgressView("Loading Mobi...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await loadMobi() }
            }

        case .chm:
            if let webReaderContent {
                WebBasedReaderWrapper(
                    book: book,
                    content: webReaderContent,
                    currentChapter: $currentChapter,
                    totalChapters: $totalChapters,
                    paginatedPage: $webPaginatedPage,
                    paginatedTotalPages: $webPaginatedTotalPages,
                    viewMode: readerViewMode,
                    annotationState: annotationState
                )
            } else {
                ProgressView("Loading CHM...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await loadCHM() }
            }
        }
    }

    // MARK: - Toolbar

    private var readerToolbar: some View {
        return ReaderToolbar(
            book: book,
            currentPage: book.format == .pdf ? currentPage : webPaginatedPage,
            totalPages: book.format == .pdf ? totalPages : webPaginatedTotalPages,
            showTOC: $showTOC,
            showSearch: $showSearchPanel,
            readerViewMode: $readerViewMode,
            hasTOC: hasTOC,
            pageLabel: "Page"
        )
    }

    private var hasTOC: Bool {
        switch book.format {
        case .pdf:
            pdfDocument?.outlineRoot != nil
                && (pdfDocument?.outlineRoot?.numberOfChildren ?? 0) > 0
        case .epub:
            epubContent?.toc.isEmpty == false
        case .fb2:
            fb2Content?.sections.isEmpty == false
        case .mobi, .azw3:
            mobiContent?.chapters.isEmpty == false
        case .chm:
            chmContent?.sections.isEmpty == false
        }
    }

    // MARK: - ePub Loading

    private func loadEPub() async {
        let parser = EPubParser()
        do {
            let content = try await parser.parse(bookURL: book.fileURL, bookID: book.id)
            epubContent = content

            // Build combined document — used for ALL modes (scroll + paginated)
            // This gives us exact book-wide page counts and seamless chapter transitions
            guard let combinedURL = try? await parser.buildCombinedDocument(for: content) else { return }
            epubCombinedURL = combinedURL

            let position = ReadingPosition.fromJSON(book.lastReadPosition)
            var scrollFraction = 0.0
            if case .epub(_, let sf) = position {
                scrollFraction = sf
            }

            webReaderContent = .epubChapter(
                chapterURL: combinedURL,
                baseURL: content.extractedBaseURL,
                spineIndex: 0,
                totalSpineItems: 1,
                scrollFraction: scrollFraction
            )
        } catch {
            // Parser failed — loading spinner remains visible
        }
    }

    private func navigateEPub(to href: String) {
        guard let epubContent else { return }

        // href might contain a fragment: "chapter1.xhtml#section2"
        let parts = href.split(separator: "#", maxSplits: 1)
        let filePart = String(parts.first ?? "")

        // Find matching spine item
        if let spineIndex = epubContent.spine.firstIndex(where: { spineItem in
            spineItem.href == filePart || spineItem.href.hasSuffix("/\(filePart)")
        }) {
            // Use notification so the coordinator loads the chapter directly
            NotificationCenter.default.post(
                name: .ebookReaderNavigateToSpineIndex,
                object: spineIndex
            )
        }

        // Handle fragment navigation
        if parts.count > 1 {
            let fragment = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NotificationCenter.default.post(
                    name: .ebookReaderNavigateToWebContent,
                    object: WebNavigationTargetWrapper(.scrollToAnchor(fragment))
                )
            }
        }
    }

    // MARK: - FB2 Loading

    private func loadFB2() async {
        let parser = FB2Parser()
        do {
            let content = try await parser.parse(bookURL: book.fileURL)
            fb2Content = content

            let position = ReadingPosition.fromJSON(book.lastReadPosition)
            var scrollFraction = 0.0
            if case .fb2(let sf) = position {
                scrollFraction = sf
            }

            webReaderContent = .fb2HTML(
                html: content.htmlContent,
                sectionCount: content.sections.count,
                scrollFraction: scrollFraction
            )
        } catch {
            // Parser failed — loading spinner remains visible
        }
    }

    // MARK: - Mobi Loading

    private func loadMobi() async {
        let parser = MobiParser()
        do {
            let content = try await parser.parse(bookURL: book.fileURL)
            mobiContent = content

            let position = ReadingPosition.fromJSON(book.lastReadPosition)
            var scrollFraction = 0.0
            if case .webBased(let sf) = position {
                scrollFraction = sf
            }

            webReaderContent = .mobiHTML(
                html: content.htmlContent,
                chapterCount: content.chapters.count,
                scrollFraction: scrollFraction
            )
        } catch {
            // Parser failed — loading spinner remains visible
        }
    }

    // MARK: - CHM Loading

    private func loadCHM() async {
        let parser = CHMParser()
        do {
            let content = try await parser.parse(bookURL: book.fileURL)
            chmContent = content

            let position = ReadingPosition.fromJSON(book.lastReadPosition)
            var scrollFraction = 0.0
            if case .webBased(let sf) = position {
                scrollFraction = sf
            }

            webReaderContent = .chmHTML(
                html: content.htmlContent,
                sectionCount: content.sections.count,
                scrollFraction: scrollFraction
            )
        } catch {
            // Parser failed — loading spinner remains visible
        }
    }
}

// MARK: - ePub Reader Wrapper (handles position saving)

private struct EPubReaderWrapper: View {
    @Environment(AppState.self) private var appState
    let book: Book
    let content: WebReaderContent
    @Binding var currentChapter: Int
    @Binding var totalChapters: Int
    @Binding var paginatedPage: Int
    @Binding var paginatedTotalPages: Int
    let epubContent: EPubParser.EPubContent?
    let viewMode: ReaderViewMode
    var annotationState: AnnotationState

    var body: some View {
        WebReaderView(
            content: content,
            viewMode: viewMode,
            currentChapter: $currentChapter,
            totalChapters: $totalChapters,
            paginatedPage: $paginatedPage,
            paginatedTotalPages: $paginatedTotalPages,
            annotationState: annotationState,
            bookId: book.id,
            epubContent: epubContent
        )
    }
}

// MARK: - FB2 Reader Wrapper (handles position saving)

private struct FB2ReaderWrapper: View {
    @Environment(AppState.self) private var appState
    let book: Book
    let content: WebReaderContent
    @Binding var currentChapter: Int
    @Binding var totalChapters: Int
    @Binding var paginatedPage: Int
    @Binding var paginatedTotalPages: Int
    let viewMode: ReaderViewMode
    var annotationState: AnnotationState

    var body: some View {
        WebReaderView(
            content: content,
            viewMode: viewMode,
            currentChapter: $currentChapter,
            totalChapters: $totalChapters,
            paginatedPage: $paginatedPage,
            paginatedTotalPages: $paginatedTotalPages,
            annotationState: annotationState,
            bookId: book.id
        )
    }
}

// MARK: - Web-Based Reader Wrapper (Mobi, CHM — single HTML page, like FB2)

private struct WebBasedReaderWrapper: View {
    @Environment(AppState.self) private var appState
    let book: Book
    let content: WebReaderContent
    @Binding var currentChapter: Int
    @Binding var totalChapters: Int
    @Binding var paginatedPage: Int
    @Binding var paginatedTotalPages: Int
    let viewMode: ReaderViewMode
    var annotationState: AnnotationState

    var body: some View {
        WebReaderView(
            content: content,
            viewMode: viewMode,
            currentChapter: $currentChapter,
            totalChapters: $totalChapters,
            paginatedPage: $paginatedPage,
            paginatedTotalPages: $paginatedTotalPages,
            annotationState: annotationState,
            bookId: book.id
        )
    }
}

// MARK: - PDF Reader Wrapper (handles navigation + position saving)

/// PDF display mode options
enum ReaderViewMode: String, CaseIterable {
    case freeScroll = "Scroll"
    case singlePage = "Single Page"
    case twoPage = "Two Page"

    var systemImage: String {
        switch self {
        case .freeScroll: "arrow.up.and.down.text.horizontal"
        case .singlePage: "doc"
        case .twoPage: "book"
        }
    }
}

private struct PDFReaderViewWrapper: NSViewRepresentable {
    @Environment(AppState.self) private var appState
    @Environment(InBookSearchState.self) private var searchState
    let book: Book
    @Binding var currentPage: Int
    @Binding var totalPages: Int
    @Binding var pdfDocument: PDFDocument?
    let viewMode: ReaderViewMode
    var annotationState: AnnotationState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        applyDisplayMode(pdfView, mode: viewMode)
        applyPageStyling(pdfView)

        if let document = PDFDocument(url: book.fileURL) {
            pdfView.document = document

            Task { @MainActor in
                pdfDocument = document
                totalPages = document.pageCount
            }

            // Restore reading position
            let position = ReadingPosition.fromJSON(book.lastReadPosition)
            if case .pdf(let pageIndex, _) = position,
               pageIndex < document.pageCount,
               let page = document.page(at: pageIndex) {
                pdfView.go(to: page)
            }
        }

        context.coordinator.pdfView = pdfView
        context.coordinator.bookID = book.id
        context.coordinator.setupEventMonitors()

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.navigateToDestination(_:)),
            name: .ebookReaderNavigateToDestination,
            object: nil
        )

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.findInBook(_:)),
            name: .ebookReaderFindInBook,
            object: nil
        )

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.navigateToMatch(_:)),
            name: .ebookReaderFindNavigate,
            object: nil
        )

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.goToPage(_:)),
            name: .ebookReaderGoToPage,
            object: nil
        )

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleSelectionComplete(_:)),
            name: .ebookReaderCreateAnnotationFromSelection,
            object: nil
        )

        // Observe PDF selection changes for annotation creation
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged(_:)),
            name: .PDFViewSelectionChanged,
            object: pdfView
        )

        // Observe annotation refresh requests (after delete/color change)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.refreshAnnotations(_:)),
            name: .ebookReaderRefreshAnnotations,
            object: nil
        )

        // Restore saved annotations
        context.coordinator.restoreAnnotations(from: annotationState.annotations)

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        let coord = context.coordinator

        // Apply display mode if it changed
        if coord.currentViewMode != viewMode {
            let currentPage = pdfView.currentPage
            applyDisplayMode(pdfView, mode: viewMode)
            coord.currentViewMode = viewMode
            if let page = currentPage {
                pdfView.go(to: page)
            }
        }

        coord.hapticEnabled = appState.pageHapticFeedback
        coord.scrollThreshold = 40 + CGFloat(appState.pageScrollResistance) * 210

        // Apply theme background
        pdfView.backgroundColor = appState.readerTheme.nsPdfBackground

        coord.searchState = searchState
        coord.annotationState = annotationState

        // Set callbacks once — use coordinator-stored bindings to avoid
        // re-creating closures on every updateNSView call (which triggers
        // a SwiftUI re-render cascade and spikes CPU during PDF scrolling).
        if !coord.callbacksConfigured {
            coord.callbacksConfigured = true
            coord.currentPageBinding = $currentPage
            coord.totalPagesBinding = $totalPages
            let bookId = book.id
            let repository = appState.repository!
            let annotationRepo = appState.annotationRepository!
            coord.onSavePosition = { position in
                Task {
                    try? await repository.updateLastReadPosition(
                        bookId: bookId,
                        position: position.toJSON() ?? ""
                    )
                }
            }
            coord.onAnnotationCreated = { [annotationState] annotation in
                Task { @MainActor in
                    _ = try? await annotationRepo.insertAnnotation(annotation)
                    let loaded = (try? await annotationRepo.fetchAnnotations(forBook: bookId)) ?? []
                    annotationState.annotations = loaded

                    // Auto-open note editor for comment/freeText tools
                    if annotation.tool == .comment || annotation.tool == .freeText {
                        annotationState.selectedAnnotationID = annotation.id
                    }
                }
            }
        }

        // Manage mouse monitors for shape drawing
        if annotationState.activeTool?.isShapeTool == true {
            coord.setupMouseMonitors()
        } else {
            coord.teardownMouseMonitors()
        }
    }

    private func applyDisplayMode(_ pdfView: PDFView, mode: ReaderViewMode) {
        switch mode {
        case .freeScroll:
            pdfView.displayMode = .singlePageContinuous
        case .singlePage:
            pdfView.displayMode = .singlePage
        case .twoPage:
            pdfView.displayMode = .twoUp
        }
        pdfView.displaysPageBreaks = true
        applyPageStyling(pdfView)
        // Ensure focus for arrow key navigation
        DispatchQueue.main.async {
            pdfView.window?.makeFirstResponder(pdfView)
        }
    }

    private func applyPageStyling(_ pdfView: PDFView) {
        pdfView.pageBreakMargins = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        pdfView.backgroundColor = NSColor(white: 0.88, alpha: 1.0)
        if pdfView.responds(to: Selector(("setPageShadowsEnabled:"))) {
            pdfView.setValue(true, forKey: "pageShadowsEnabled")
        }
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        coordinator.teardownEventMonitors()
        NotificationCenter.default.removeObserver(coordinator)
        coordinator.saveCurrentPosition()
    }

    @MainActor
    class Coordinator: NSObject {
        weak var pdfView: PDFView?
        var bookID: UUID?
        var searchState: InBookSearchState?
        var annotationState: AnnotationState?
        var currentViewMode: ReaderViewMode = .freeScroll
        var hapticEnabled: Bool = false
        var onSavePosition: (@Sendable (ReadingPosition) -> Void)?
        var onAnnotationCreated: (@Sendable (Annotation) -> Void)?

        // Bindings written directly from pageChanged — avoids closure re-creation
        var callbacksConfigured = false
        var currentPageBinding: Binding<Int>?
        var totalPagesBinding: Binding<Int>?

        private var findSelections: [PDFSelection] = []

        // Shape drawing state
        private var shapeStartPoint: NSPoint?
        private var shapeCurrentPoint: NSPoint?
        private var shapeTempAnnotation: PDFAnnotation?
        private var mouseMonitor: Any?

        // Track our managed annotations by ID → (PDFAnnotation, pageIndex)
        // so we can remove them without scanning all pages
        private var managedAnnotations: [UUID: (pdfAnnotation: PDFAnnotation, pageIndex: Int)] = [:]

        // Event monitors for paginated scroll/key handling
        private var scrollMonitor: Any?
        private var keyMonitor: Any?
        private var scrollAccumulator: CGFloat = 0
        /// Configurable threshold: mapped from AppState.pageScrollResistance (0…1 → 40…250)
        var scrollThreshold: CGFloat = 145
        // Post-flip dynamics
        private var lastFlipTime: CFTimeInterval = 0
        private let flipCooldown: CFTimeInterval = 0.2 // absorb momentum after each flip
        private var consecutiveFlips: Int = 0

        // Throttle pageChanged to avoid Task spam during rapid scrolling
        private var pageChangeCoalesceTimer: Timer?
        private var lastReportedPage: Int = -1

        // Cache the scroll view reference to avoid recursive search each event
        private weak var cachedScrollView: NSScrollView?

        deinit {
            // Timer and event-monitor teardown must happen on the main thread.
            // Coordinators are always created and released on the main actor, so
            // MainActor.assumeIsolated is safe here and satisfies strict concurrency.
            MainActor.assumeIsolated {
                pageChangeCoalesceTimer?.invalidate()
                pendingSelectionTimer?.invalidate()
                teardownEventMonitors()
            }
        }

        func setupEventMonitors() {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let transfer = NSEventTransfer(event: event)
                guard let self else { return transfer.event }
                return MainActor.assumeIsolated { self.handleScrollEvent(transfer.event) }
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let transfer = NSEventTransfer(event: event)
                guard let self else { return transfer.event }
                return MainActor.assumeIsolated { self.handleKeyEvent(transfer.event) }
            }
        }

        func setupMouseMonitors() {
            teardownMouseMonitors()
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                let transfer = NSEventTransfer(event: event)
                guard let self else { return transfer.event }
                return MainActor.assumeIsolated { self.handleMouseEvent(transfer.event) }
            }
        }

        func teardownMouseMonitors() {
            if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        }

        func teardownEventMonitors() {
            if let m = scrollMonitor { NSEvent.removeMonitor(m); scrollMonitor = nil }
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            teardownMouseMonitors()
        }

        private func handleScrollEvent(_ event: NSEvent) -> NSEvent? {
            guard let pdfView,
                  pdfView.displayMode == .singlePage || pdfView.displayMode == .twoUp else {
                return event
            }
            // Only handle events over our PDFView
            guard let window = pdfView.window, event.window === window else { return event }
            let loc = pdfView.convert(event.locationInWindow, from: nil)
            guard pdfView.bounds.contains(loc) else { return event }

            if event.phase == .began || event.phase == .mayBegin {
                scrollAccumulator = 0
                consecutiveFlips = 0
            }
            if event.phase == .ended || event.phase == .cancelled {
                scrollAccumulator = 0
                consecutiveFlips = 0
                return nil
            }

            // Check if the page is larger than the viewport (zoomed in / small window)
            let boundary = scrollBoundaryState(of: pdfView)

            if boundary.canScrollInternally {
                // Page doesn't fit — allow intra-page scrolling until at a boundary
                let scrollingDown = event.scrollingDeltaY < 0
                let scrollingUp = event.scrollingDeltaY > 0

                if scrollingDown && boundary.atBottom {
                    return accumulateAndFlip(event, pdfView: pdfView)
                } else if scrollingUp && boundary.atTop {
                    return accumulateAndFlip(event, pdfView: pdfView)
                } else {
                    // Still within page — pass through for normal scroll
                    scrollAccumulator = 0
                    return event
                }
            } else {
                // Page fits in viewport — all scroll goes to page navigation
                return accumulateAndFlip(event, pdfView: pdfView)
            }
        }

        /// Detects whether the internal scroll view has room to scroll and the current edge state.
        private func scrollBoundaryState(of pdfView: PDFView)
            -> (canScrollInternally: Bool, atTop: Bool, atBottom: Bool)
        {
            // Use cached scroll view to avoid recursive subview search on every scroll event
            if cachedScrollView == nil || cachedScrollView?.superview == nil {
                func findScrollView(in view: NSView) -> NSScrollView? {
                    for sub in view.subviews {
                        if let sv = sub as? NSScrollView { return sv }
                        if let found = findScrollView(in: sub) { return found }
                    }
                    return nil
                }
                cachedScrollView = findScrollView(in: pdfView)
            }

            guard let scrollView = cachedScrollView,
                  let docView = scrollView.documentView else {
                return (false, true, true)
            }

            let visible = scrollView.documentVisibleRect
            let docH = docView.frame.height
            let canScroll = docH > visible.height + 1

            let atTop: Bool
            let atBottom: Bool
            if scrollView.contentView.isFlipped {
                atTop = visible.origin.y <= 1
                atBottom = visible.maxY >= docH - 1
            } else {
                atBottom = visible.origin.y <= 1
                atTop = visible.maxY >= docH - 1
            }
            return (canScroll, atTop, atBottom)
        }

        /// Accumulates scroll delta and flips page when threshold exceeded.
        /// Uses a cooldown after each flip to absorb leftover momentum, then
        /// lowers the threshold for sustained scrolling so it speeds up naturally.
        private func accumulateAndFlip(_ event: NSEvent, pdfView: PDFView) -> NSEvent? {
            let now = CACurrentMediaTime()
            let elapsed = now - lastFlipTime

            // During cooldown after a flip, consume events but don't accumulate.
            // This absorbs the leftover momentum that would otherwise skip pages.
            if elapsed < flipCooldown {
                scrollAccumulator = 0
                return nil
            }

            let dy = event.scrollingDeltaY
            let dx = event.scrollingDeltaX
            let raw = abs(dy) >= abs(dx) ? dy : dx
            let delta: CGFloat = event.hasPreciseScrollingDeltas ? -raw : -raw * 10

            scrollAccumulator += delta

            // Sustained scrolling: aggressively lower threshold for consecutive flips.
            // 1st flip: 100%, 2nd: 40%, 3rd+: 20% (near-instant).
            let effective: CGFloat
            if consecutiveFlips > 0 {
                effective = scrollThreshold * max(0.15, pow(0.4, CGFloat(min(consecutiveFlips, 4))))
            } else {
                effective = scrollThreshold
            }

            if scrollAccumulator > effective {
                scrollAccumulator = 0
                lastFlipTime = now
                consecutiveFlips += 1
                if pdfView.canGoToNextPage {
                    pdfView.goToNextPage(nil)
                    fireHaptic()
                }
            } else if scrollAccumulator < -effective {
                scrollAccumulator = 0
                lastFlipTime = now
                consecutiveFlips += 1
                if pdfView.canGoToPreviousPage {
                    pdfView.goToPreviousPage(nil)
                    fireHaptic()
                }
            }
            return nil
        }

        private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
            guard let pdfView,
                  pdfView.displayMode == .singlePage || pdfView.displayMode == .twoUp,
                  pdfView.window?.isKeyWindow == true else {
                return event
            }
            switch event.keyCode {
            case 124, 125: // Right, Down
                if pdfView.canGoToNextPage {
                    pdfView.goToNextPage(nil)
                    fireHaptic()
                }
                return nil
            case 123, 126: // Left, Up
                if pdfView.canGoToPreviousPage {
                    pdfView.goToPreviousPage(nil)
                    fireHaptic()
                }
                return nil
            default:
                return event
            }
        }

        private func fireHaptic() {
            guard hapticEnabled else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView,
                  let document = pdfView.document,
                  let currentPage = pdfView.currentPage else { return }
            let pageIndex = document.index(for: currentPage)
            let total = document.pageCount

            // Skip if page hasn't actually changed
            guard pageIndex != lastReportedPage else { return }

            // Coalesce rapid updates — only commit after 0.05s of no change.
            // This prevents hundreds of Tasks and re-renders during fast scrolling.
            pageChangeCoalesceTimer?.invalidate()
            pageChangeCoalesceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.lastReportedPage = pageIndex
                    self.currentPageBinding?.wrappedValue = pageIndex
                    self.totalPagesBinding?.wrappedValue = total
                }
            }
        }

        @objc func navigateToDestination(_ notification: Notification) {
            guard let destination = notification.object as? PDFDestination else { return }
            pdfView?.go(to: destination)
        }

        @objc func goToPage(_ notification: Notification) {
            guard let pageIndex = notification.object as? Int,
                  let pdfView,
                  let document = pdfView.document,
                  let page = document.page(at: pageIndex) else { return }
            pdfView.go(to: page)
        }

        @objc func findInBook(_ notification: Notification) {
            guard let query = notification.object as? String,
                  !query.isEmpty,
                  let pdfView,
                  let document = pdfView.document,
                  let searchState else { return }

            let selections = document.findString(query, withOptions: .caseInsensitive)
            findSelections = selections

            searchState.totalMatches = selections.count
            searchState.isSearching = false

            if selections.isEmpty {
                searchState.currentMatchIndex = 0
                searchState.results = []
                return
            }

            // Build results list with page numbers and context
            var results: [InBookSearchState.SearchMatch] = []
            var pageMatchCounts: [Int: Int] = [:] // track Nth occurrence per page
            for (i, sel) in selections.enumerated() {
                let pageIndex = sel.pages.first.map { document.index(for: $0) } ?? 0
                let pageLabel = "Page \(pageIndex + 1)"
                let occurrenceOnPage = pageMatchCounts[pageIndex, default: 0]
                pageMatchCounts[pageIndex] = occurrenceOnPage + 1

                // Get surrounding text for the Nth occurrence on this page
                var context = sel.string ?? query
                if let page = sel.pages.first, let pageText = page.string {
                    let matchText = sel.string ?? query
                    var searchRange = pageText.startIndex..<pageText.endIndex
                    var found = 0
                    while let range = pageText.range(of: matchText, options: .caseInsensitive, range: searchRange) {
                        if found == occurrenceOnPage {
                            let before = pageText[pageText.startIndex..<range.lowerBound].suffix(30)
                            let after = pageText[range.upperBound...].prefix(30)
                            context = "...\(before)\(matchText)\(after)..."
                            break
                        }
                        found += 1
                        searchRange = range.upperBound..<pageText.endIndex
                    }
                }

                results.append(InBookSearchState.SearchMatch(
                    pageLabel: pageLabel,
                    context: context,
                    index: i
                ))
            }
            searchState.results = results
            searchState.currentMatchIndex = 0

            // Navigate to first match
            highlightMatch(at: 0)
        }

        @objc func navigateToMatch(_ notification: Notification) {
            guard let request = notification.object as? FindNavigationRequest else { return }
            highlightMatch(at: request.index)
        }

        private func highlightMatch(at index: Int) {
            guard index >= 0, index < findSelections.count,
                  let pdfView else { return }

            let selection = findSelections[index]
            pdfView.setCurrentSelection(selection, animate: true)
            if let page = selection.pages.first {
                pdfView.go(to: page)
            }
        }

        func saveCurrentPosition() {
            guard let pdfView,
                  let currentPage = pdfView.currentPage,
                  let document = pdfView.document else { return }
            let pageIndex = document.index(for: currentPage)
            let position = ReadingPosition.pdf(pageIndex: pageIndex, scrollFraction: 0)
            onSavePosition?(position)
        }

        // MARK: - Text Selection → Annotation

        private var pendingSelectionTimer: Timer?

        @objc func selectionChanged(_ notification: Notification) {
            // Wait for selection to stabilize (user finishes dragging)
            pendingSelectionTimer?.invalidate()
            pendingSelectionTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.commitPendingSelection()
                }
            }
        }

        private func commitPendingSelection() {
            guard let pdfView,
                  let annotationState,
                  let tool = annotationState.activeTool,
                  tool.isTextBased,
                  tool != .freeText,
                  let selection = pdfView.currentSelection,
                  let text = selection.string,
                  !text.isEmpty else { return }

            createTextAnnotation(from: selection)
        }

        @objc func handleSelectionComplete(_ notification: Notification) {
            commitPendingSelection()
        }

        @objc func refreshAnnotations(_ notification: Notification) {
            guard let annotationState else { return }
            restoreAnnotations(from: annotationState.annotations)
        }

        func createTextAnnotation(from selection: PDFSelection) {
            guard let pdfView,
                  let annotationState,
                  let tool = annotationState.activeTool,
                  let document = pdfView.document,
                  let bookID else { return }

            let color = annotationState.activeColor
            let selectedText = selection.string ?? ""

            // Create PDFAnnotation for each page the selection spans
            for page in selection.pages {
                let pageIndex = document.index(for: page)
                let pageBounds = selection.bounds(for: page)

                let annotationId = UUID()

                let pdfAnnotation: PDFAnnotation
                switch tool {
                case .highlight:
                    pdfAnnotation = PDFAnnotation(bounds: pageBounds, forType: .highlight, withProperties: nil)
                    pdfAnnotation.color = color.nsColor.withAlphaComponent(0.35)
                case .underline:
                    pdfAnnotation = PDFAnnotation(bounds: pageBounds, forType: .underline, withProperties: nil)
                    pdfAnnotation.color = color.nsColor
                case .strikethrough:
                    pdfAnnotation = PDFAnnotation(bounds: pageBounds, forType: .strikeOut, withProperties: nil)
                    pdfAnnotation.color = color.nsColor
                case .comment:
                    let noteBounds = CGRect(x: pageBounds.maxX, y: pageBounds.maxY - 20, width: 20, height: 20)
                    pdfAnnotation = PDFAnnotation(bounds: noteBounds, forType: .text, withProperties: nil)
                    pdfAnnotation.color = color.nsColor
                    pdfAnnotation.contents = ""
                default:
                    continue
                }

                // Tag and track so restoreAnnotations can manage it efficiently
                pdfAnnotation.userName = "\(Self.appAnnotationPrefix)\(annotationId.uuidString)"
                page.addAnnotation(pdfAnnotation)
                managedAnnotations[annotationId] = (pdfAnnotation: pdfAnnotation, pageIndex: pageIndex)

                let bounds = [
                    Double(pageBounds.origin.x),
                    Double(pageBounds.origin.y),
                    Double(pageBounds.width),
                    Double(pageBounds.height),
                ]
                let position = AnnotationPosition.pdf(pageIndex: pageIndex, bounds: bounds)

                let annotation = Annotation(
                    id: annotationId,
                    bookId: bookID,
                    tool: tool,
                    color: color,
                    position: position,
                    selectedText: selectedText
                )

                onAnnotationCreated?(annotation)
            }

            pdfView.clearSelection()
        }

        // MARK: - Shape Drawing

        private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
            guard let pdfView,
                  let annotationState,
                  let tool = annotationState.activeTool,
                  tool.isShapeTool else { return event }

            guard let window = pdfView.window, event.window === window else { return event }
            let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
            guard pdfView.bounds.contains(viewPoint) else { return event }

            switch event.type {
            case .leftMouseDown:
                guard let page = pdfView.page(for: viewPoint, nearest: true) else { return event }
                let pagePoint = pdfView.convert(viewPoint, to: page)
                shapeStartPoint = pagePoint
                shapeCurrentPoint = pagePoint
                return nil

            case .leftMouseDragged:
                guard let start = shapeStartPoint,
                      let page = pdfView.currentPage else { return event }
                let pagePoint = pdfView.convert(viewPoint, to: page)
                shapeCurrentPoint = pagePoint

                // Remove temp annotation
                if let temp = shapeTempAnnotation {
                    page.removeAnnotation(temp)
                }

                let bounds = CGRect(
                    x: min(start.x, pagePoint.x),
                    y: min(start.y, pagePoint.y),
                    width: abs(pagePoint.x - start.x),
                    height: abs(pagePoint.y - start.y)
                )

                let temp = createShapeAnnotation(tool: tool, bounds: bounds, color: annotationState.activeColor)
                if let temp {
                    page.addAnnotation(temp)
                    shapeTempAnnotation = temp
                }
                pdfView.setNeedsDisplay(pdfView.bounds)
                return nil

            case .leftMouseUp:
                guard let start = shapeStartPoint,
                      let end = shapeCurrentPoint,
                      let page = pdfView.currentPage,
                      let document = pdfView.document,
                      let bookID else {
                    shapeStartPoint = nil
                    shapeCurrentPoint = nil
                    shapeTempAnnotation = nil
                    return event
                }

                // Remove temp and create final
                if let temp = shapeTempAnnotation {
                    page.removeAnnotation(temp)
                }

                let bounds = CGRect(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: abs(end.x - start.x),
                    height: abs(end.y - start.y)
                )

                // Only create if the shape has meaningful size
                if bounds.width > 5 || bounds.height > 5 {
                    let color = annotationState.activeColor
                    let annotationId = UUID()

                    let pageIndex = document.index(for: page)
                    let final = createShapeAnnotation(tool: tool, bounds: bounds, color: color)
                    if let final {
                        final.userName = "\(Self.appAnnotationPrefix)\(annotationId.uuidString)"
                        page.addAnnotation(final)
                        managedAnnotations[annotationId] = (pdfAnnotation: final, pageIndex: pageIndex)
                    }

                    let positionBounds = [
                        Double(bounds.origin.x),
                        Double(bounds.origin.y),
                        Double(bounds.width),
                        Double(bounds.height),
                    ]
                    let position = AnnotationPosition.pdf(pageIndex: pageIndex, bounds: positionBounds)

                    var shapeData: String?
                    if tool == .line || tool == .arrow {
                        let lineData: [String: Any] = [
                            "startX": Double(start.x), "startY": Double(start.y),
                            "endX": Double(end.x), "endY": Double(end.y),
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: lineData) {
                            shapeData = String(data: data, encoding: .utf8)
                        }
                    }

                    let annotation = Annotation(
                        id: annotationId,
                        bookId: bookID,
                        tool: tool,
                        color: color,
                        position: position,
                        data: shapeData
                    )
                    onAnnotationCreated?(annotation)
                }

                shapeStartPoint = nil
                shapeCurrentPoint = nil
                shapeTempAnnotation = nil
                pdfView.setNeedsDisplay(pdfView.bounds)
                return nil

            default:
                return event
            }
        }

        private func createShapeAnnotation(tool: AnnotationTool, bounds: CGRect, color: AnnotationColor) -> PDFAnnotation? {
            let annotation: PDFAnnotation
            switch tool {
            case .line:
                annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
                annotation.startPoint = CGPoint(x: bounds.minX, y: bounds.minY)
                annotation.endPoint = CGPoint(x: bounds.maxX, y: bounds.maxY)
                annotation.color = color.nsColor
                annotation.border = PDFBorder()
                annotation.border?.lineWidth = 2
            case .arrow:
                annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
                annotation.startPoint = CGPoint(x: bounds.minX, y: bounds.minY)
                annotation.endPoint = CGPoint(x: bounds.maxX, y: bounds.maxY)
                annotation.endLineStyle = .closedArrow
                annotation.color = color.nsColor
                annotation.border = PDFBorder()
                annotation.border?.lineWidth = 2
            case .circle:
                annotation = PDFAnnotation(bounds: bounds, forType: .circle, withProperties: nil)
                annotation.color = color.nsColor
                annotation.border = PDFBorder()
                annotation.border?.lineWidth = 2
            case .square:
                annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
                annotation.color = color.nsColor
                annotation.border = PDFBorder()
                annotation.border?.lineWidth = 2
            default:
                return nil
            }
            return annotation
        }

        // MARK: - Restore Annotations from Database

        private static let appAnnotationPrefix = "__eb_"

        /// Efficiently sync visual PDF annotations with the current annotation state.
        /// Only touches pages we know about — never scans the entire document.
        func restoreAnnotations(from annotations: [Annotation]) {
            guard let pdfView, let document = pdfView.document else { return }

            // Remove only our tracked annotations (no full-document scan)
            for (_, entry) in managedAnnotations {
                if entry.pageIndex < document.pageCount,
                   let page = document.page(at: entry.pageIndex) {
                    page.removeAnnotation(entry.pdfAnnotation)
                }
            }
            managedAnnotations.removeAll()

            // Add annotations from the current state
            for annotation in annotations {
                guard let pos = annotation.decodedPosition,
                      case .pdf(let pageIndex, let bounds) = pos,
                      pageIndex < document.pageCount,
                      let page = document.page(at: pageIndex) else { continue }

                let rect: CGRect
                if let b = bounds, b.count >= 4 {
                    rect = CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
                } else {
                    continue
                }

                let pdfAnn: PDFAnnotation?
                switch annotation.tool {
                case .highlight:
                    pdfAnn = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                    pdfAnn?.color = annotation.color.nsColor.withAlphaComponent(0.35)
                case .underline:
                    pdfAnn = PDFAnnotation(bounds: rect, forType: .underline, withProperties: nil)
                    pdfAnn?.color = annotation.color.nsColor
                case .strikethrough:
                    pdfAnn = PDFAnnotation(bounds: rect, forType: .strikeOut, withProperties: nil)
                    pdfAnn?.color = annotation.color.nsColor
                case .comment:
                    pdfAnn = PDFAnnotation(bounds: CGRect(x: rect.maxX, y: rect.maxY - 20, width: 20, height: 20), forType: .text, withProperties: nil)
                    pdfAnn?.color = annotation.color.nsColor
                    pdfAnn?.contents = annotation.note ?? ""
                case .freeText:
                    pdfAnn = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
                    pdfAnn?.color = annotation.color.nsColor.withAlphaComponent(0.1)
                    pdfAnn?.contents = annotation.note ?? ""
                    pdfAnn?.font = NSFont.systemFont(ofSize: 12)
                    pdfAnn?.fontColor = annotation.color.nsColor
                case .line:
                    pdfAnn = createShapeAnnotation(tool: .line, bounds: rect, color: annotation.color)
                case .arrow:
                    pdfAnn = createShapeAnnotation(tool: .arrow, bounds: rect, color: annotation.color)
                case .circle:
                    pdfAnn = createShapeAnnotation(tool: .circle, bounds: rect, color: annotation.color)
                case .square:
                    pdfAnn = createShapeAnnotation(tool: .square, bounds: rect, color: annotation.color)
                }

                if let pdfAnn {
                    pdfAnn.userName = "\(Self.appAnnotationPrefix)\(annotation.id.uuidString)"
                    page.addAnnotation(pdfAnn)
                    managedAnnotations[annotation.id] = (pdfAnnotation: pdfAnn, pageIndex: pageIndex)
                }
            }
        }
    }
}

// MARK: - Web TOC Views

/// Table of contents for ePub (parsed from NCX/nav).
struct WebTOCListView: View {
    let items: [EPubParser.TOCItem]
    let onSelect: (String) -> Void

    var body: some View {
        List {
            ForEach(items) { item in
                WebTOCNode(item: item, onSelect: onSelect)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct WebTOCNode: View {
    let item: EPubParser.TOCItem
    let onSelect: (String) -> Void

    var body: some View {
        if item.children.isEmpty {
            Button {
                onSelect(item.href)
            } label: {
                Text(item.title)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            DisclosureGroup {
                ForEach(item.children) { child in
                    WebTOCNode(item: child, onSelect: onSelect)
                }
            } label: {
                Button {
                    onSelect(item.href)
                } label: {
                    Text(item.title)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Table of contents for FB2 (section titles).
struct FB2TOCListView: View {
    let sections: [FB2Parser.FB2Section]
    let onSelect: (String) -> Void

    var body: some View {
        List {
            ForEach(sections) { section in
                FB2TOCNode(section: section, onSelect: onSelect)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct FB2TOCNode: View {
    let section: FB2Parser.FB2Section
    let onSelect: (String) -> Void

    var body: some View {
        if let title = section.title {
            if section.children.isEmpty {
                Button {
                    onSelect(section.id)
                } label: {
                    Text(title)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                DisclosureGroup {
                    ForEach(section.children) { child in
                        FB2TOCNode(section: child, onSelect: onSelect)
                    }
                } label: {
                    Button {
                        onSelect(section.id)
                    } label: {
                        Text(title)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Mobi TOC View

struct MobiTOCListView: View {
    let chapters: [MobiParser.Chapter]
    let onSelect: (String) -> Void

    var body: some View {
        List {
            ForEach(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                Button {
                    onSelect(chapter.anchor)
                } label: {
                    Text(chapter.title)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - CHM TOC View

struct CHMTOCListView: View {
    let sections: [CHMParser.Section]
    let onSelect: (String) -> Void

    var body: some View {
        List {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                CHMTOCNode(section: section, onSelect: onSelect)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct CHMTOCNode: View {
    let section: CHMParser.Section
    let onSelect: (String) -> Void

    var body: some View {
        if section.children.isEmpty {
            Button {
                onSelect(section.path)
            } label: {
                Text(section.title)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            DisclosureGroup {
                ForEach(Array(section.children.enumerated()), id: \.offset) { _, child in
                    CHMTOCNode(section: child, onSelect: onSelect)
                }
            } label: {
                Button {
                    onSelect(section.path)
                } label: {
                    Text(section.title)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Custom Notifications

extension Notification.Name {
    static let ebookReaderNavigateToDestination = Notification.Name("ebookReaderNavigateToDestination")
    static let ebookReaderFindInBook = Notification.Name("ebookReaderFindInBook")
    static let ebookReaderToggleFindBar = Notification.Name("ebookReaderToggleFindBar")
    static let ebookReaderGoToPage = Notification.Name("ebookReaderGoToPage")
    static let ebookReaderCreateAnnotationFromSelection = Notification.Name("ebookReaderCreateAnnotationFromSelection")
    static let ebookReaderRefreshAnnotations = Notification.Name("ebookReaderRefreshAnnotations")
}

// MARK: - Note Editor Sheet

/// Sheet for editing annotation notes (comment / freeText tools).
private struct NoteEditorSheet: View {
    let annotation: Annotation
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var noteText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: annotation.tool.systemImage)
                    .foregroundStyle(annotation.color.color)
                Text(annotation.tool == .comment ? "Edit Comment" : "Edit Note")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            // Selected text context
            if let text = annotation.selectedText, !text.isEmpty {
                HStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(annotation.color.color)
                        .frame(width: 3)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // Note editor
            TextEditor(text: $noteText)
                .font(.body)
                .frame(minHeight: 120)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding()

            Divider()

            // Buttons
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { onSave(noteText) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(width: 400, height: 320)
        .onAppear {
            noteText = annotation.note ?? ""
        }
    }
}
