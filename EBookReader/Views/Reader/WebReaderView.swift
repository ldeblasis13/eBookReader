import SwiftUI
import WebKit

/// Wraps WKWebView for rendering ePub chapters and FB2 content.
struct WebReaderView: NSViewRepresentable {
    @Environment(InBookSearchState.self) private var searchState
    @Environment(AppState.self) private var appState
    let content: WebReaderContent
    let viewMode: ReaderViewMode
    @Binding var currentChapter: Int
    @Binding var totalChapters: Int
    @Binding var paginatedPage: Int
    @Binding var paginatedTotalPages: Int
    var annotationState: AnnotationState?
    var bookId: UUID?
    var epubContent: EPubParser.EPubContent?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Use a weak proxy to break the strong reference cycle:
        // WKUserContentController → handler → coordinator → WKWebView → configuration → controller
        let proxy = WeakScriptMessageHandler(delegate: context.coordinator)
        config.userContentController.add(proxy, name: "scrollPosition")
        config.userContentController.add(proxy, name: "searchResults")
        config.userContentController.add(proxy, name: "paginationState")
        config.userContentController.add(proxy, name: "annotationSelection")
        config.userContentController.add(proxy, name: "chapterBoundary")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.viewMode = viewMode
        context.coordinator.annotationState = annotationState
        context.coordinator.bookId = bookId

        loadContent(in: webView, context: context)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleSpineNavigation(_:)),
            name: .ebookReaderNavigateToSpineIndex,
            object: nil
        )

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleNavigation(_:)),
            name: .ebookReaderNavigateToWebContent,
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
            selector: #selector(Coordinator.refreshAnnotations(_:)),
            name: .ebookReaderRefreshAnnotations,
            object: nil
        )

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        coord.searchState = searchState
        coord.annotationState = annotationState
        coord.bookId = bookId
        coord.epubContent = epubContent

        // Detect chapter/content change and reload if needed
        let contentChanged = !coord.isSameContent(content)
        coord.content = content

        // Set callbacks once to avoid closure re-creation on every updateNSView call.
        // Bindings are structs (stable for the view's lifetime) so capture by value is fine.
        if coord.onChapterChange == nil {
            let chapterBinding = $currentChapter
            let totalBinding = $totalChapters
            coord.onChapterChange = { chapter, total in
                Task { @MainActor in
                    chapterBinding.wrappedValue = chapter
                    totalBinding.wrappedValue = total
                }
            }
        }
        if coord.onPaginationChange == nil {
            let pageBinding = $paginatedPage
            let totalBinding = $paginatedTotalPages
            coord.onPaginationChange = { page, total in
                Task { @MainActor in
                    pageBinding.wrappedValue = page
                    totalBinding.wrappedValue = total
                }
            }
        }
        if coord.onSavePosition == nil, let bookId {
            let repository = appState.repository!
            coord.onSavePosition = { position in
                Task {
                    try? await repository.updateLastReadPosition(
                        bookId: bookId,
                        position: position.toJSON() ?? ""
                    )
                }
            }
        }
        if coord.onAnnotationCreated == nil, let annotationState, let bookId {
            let annotationRepo = appState.annotationRepository!
            coord.onAnnotationCreated = { [weak annotationState] annotation in
                Task { @MainActor in
                    guard let annotationState else { return }
                    _ = try? await annotationRepo.insertAnnotation(annotation)
                    let loaded = (try? await annotationRepo.fetchAnnotations(forBook: bookId)) ?? []
                    annotationState.annotations = loaded
                    coord.applyAnnotations()
                }
            }
        }
        if coord.onChapterAdvance == nil {
            coord.onChapterAdvance = { [weak coord] newSpineIndex, startAtEnd in
                guard let coord else { return }
                NotificationCenter.default.post(
                    name: .ebookReaderNavigateToSpineIndex,
                    object: newSpineIndex,
                    userInfo: startAtEnd ? ["startAtEnd": true] : nil
                )
            }
        }

        // Reload content if it changed (e.g., ePub chapter navigation)
        if contentChanged {
            reloadContent(in: webView, context: context)
            return // didFinish will handle theme, annotations, pagination
        }

        // Update annotation mode in JS only when needed
        if let annotationState {
            let isActive = annotationState.activeTool?.isTextBased == true
            webView.evaluateJavaScript(Coordinator.setAnnotationActiveJS(isActive), completionHandler: nil)
        }

        // Apply view mode change
        if coord.viewMode != viewMode {
            coord.viewMode = viewMode
            coord.applyViewMode()
        }

        // Apply theme / font size change
        if coord.currentTheme != appState.readerTheme
            || coord.currentFontSize != appState.readerFontSize {
            coord.currentTheme = appState.readerTheme
            coord.currentFontSize = appState.readerFontSize
            coord.applyTheme()
            // Re-apply pagination after theme so gradient CSS takes priority
            coord.applyViewMode()
        }
    }

    /// Reloads content into an existing WKWebView (used when chapter changes).
    private func reloadContent(in webView: WKWebView, context: Context) {
        switch content {
        case .epubChapter(let chapterURL, let baseURL, let spineIndex, let totalSpineItems, _):
            totalChapters = totalSpineItems
            currentChapter = spineIndex
            webView.loadFileURL(chapterURL, allowingReadAccessTo: baseURL)

        case .fb2HTML(let html, let sectionCount, _):
            totalChapters = sectionCount
            currentChapter = 0
            webView.loadHTMLString(html, baseURL: nil)

        case .mobiHTML(let html, let chapterCount, _):
            totalChapters = chapterCount
            currentChapter = 0
            webView.loadHTMLString(html, baseURL: nil)

        case .chmHTML(let html, let sectionCount, _):
            totalChapters = sectionCount
            currentChapter = 0
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Flush final reading position before teardown
        coordinator.saveCurrentPosition()
        NotificationCenter.default.removeObserver(coordinator)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "scrollPosition")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "searchResults")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "paginationState")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "annotationSelection")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "chapterBoundary")
    }

    private func loadContent(in webView: WKWebView, context: Context) {
        context.coordinator.content = content

        switch content {
        case .epubChapter(let chapterURL, let baseURL, let spineIndex, let totalSpineItems, _):
            totalChapters = totalSpineItems
            currentChapter = spineIndex
            webView.loadFileURL(chapterURL, allowingReadAccessTo: baseURL)

        case .fb2HTML(let html, let sectionCount, _):
            totalChapters = sectionCount
            currentChapter = 0
            webView.loadHTMLString(html, baseURL: nil)

        case .mobiHTML(let html, let chapterCount, _):
            totalChapters = chapterCount
            currentChapter = 0
            webView.loadHTMLString(html, baseURL: nil)

        case .chmHTML(let html, let sectionCount, _):
            totalChapters = sectionCount
            currentChapter = 0
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}

// MARK: - Content Types

enum WebReaderContent {
    /// ePub chapter loaded from extracted file.
    case epubChapter(
        chapterURL: URL,
        baseURL: URL,
        spineIndex: Int,
        totalSpineItems: Int,
        scrollFraction: Double
    )
    /// FB2 rendered as a single HTML page.
    case fb2HTML(
        html: String,
        sectionCount: Int,
        scrollFraction: Double
    )
    /// Mobi/AZW3 rendered as a single HTML page.
    case mobiHTML(
        html: String,
        chapterCount: Int,
        scrollFraction: Double
    )
    /// CHM rendered as a single HTML page.
    case chmHTML(
        html: String,
        sectionCount: Int,
        scrollFraction: Double
    )

    var scrollFraction: Double {
        switch self {
        case .epubChapter(_, _, _, _, let f): f
        case .fb2HTML(_, _, let f): f
        case .mobiHTML(_, _, let f): f
        case .chmHTML(_, _, let f): f
        }
    }
}

/// Navigation request for web-based readers.
enum WebNavigationTarget {
    case epubChapter(spineIndex: Int)
    case scrollToAnchor(String)
    case scrollToFraction(Double)
}

// MARK: - Coordinator

extension WebReaderView {
    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var content: WebReaderContent?
        var searchState: InBookSearchState?
        var annotationState: AnnotationState?
        var bookId: UUID?
        var viewMode: ReaderViewMode = .freeScroll
        var onChapterChange: (@Sendable (Int, Int) -> Void)?
        var onSavePosition: (@Sendable (ReadingPosition) -> Void)?
        var onPaginationChange: (@Sendable (Int, Int) -> Void)?
        var onAnnotationCreated: (@Sendable (Annotation) -> Void)?
        var currentTheme: ReaderTheme = .normal
        var currentFontSize: Double = 16
        var epubContent: EPubParser.EPubContent?
        var onChapterAdvance: (@Sendable (Int, Bool) -> Void)?
        private var lastFindQuery: String = ""
        private var pendingFindAfterNavigation: Bool = false
        var pendingStartAtEnd: Bool = false

        /// Checks whether the new content represents the same loaded resource.
        func isSameContent(_ other: WebReaderContent) -> Bool {
            guard let current = content else { return false }
            switch (current, other) {
            case (.epubChapter(let a, _, let si1, _, _), .epubChapter(let b, _, let si2, _, _)):
                return a == b && si1 == si2
            case (.fb2HTML(let a, _, _), .fb2HTML(let b, _, _)):
                // HTML string identity — same pointer or same chapter reload
                return a == b
            case (.mobiHTML(let a, _, _), .mobiHTML(let b, _, _)):
                return a == b
            case (.chmHTML(let a, _, _), .chmHTML(let b, _, _)):
                return a == b
            default:
                return false
            }
        }

        deinit {
            // Safety net: clean up observer in case dismantleNSView wasn't called
            MainActor.assumeIsolated {
                NotificationCenter.default.removeObserver(self)
            }
        }

        // MARK: - Injected JavaScript

        private static let scrollTrackingJS = """
        (function() {
            if (window.__ebScrollTracking) return;
            window.__ebScrollTracking = true;
            let debounce;
            window.addEventListener('scroll', function() {
                clearTimeout(debounce);
                debounce = setTimeout(function() {
                    if (window.__ebPaginated) return;
                    let fraction = 0;
                    let scrollable = document.body.scrollHeight - window.innerHeight;
                    if (scrollable > 0) {
                        fraction = window.scrollY / scrollable;
                    }
                    window.webkit.messageHandlers.scrollPosition.postMessage(fraction);
                }, 200);
            });
        })();
        """

        /// JS that detects scrolling past the end or before the beginning of a chapter,
        /// and posts a message to Swift to advance to the next/previous chapter.
        /// Uses an accumulator pattern so a single small scroll doesn't trigger.
        private static let chapterBoundaryJS = """
        (function() {
            if (window.__ebChapterBoundary) return;
            window.__ebChapterBoundary = true;
            var cooldown = false;
            var boundaryAcc = 0;
            var boundaryThreshold = 400;
            var boundaryDir = 0;

            function fireBoundary(dir) {
                boundaryAcc = 0;
                boundaryDir = 0;
                cooldown = true;
                setTimeout(function() { cooldown = false; }, 1200);
                window.webkit.messageHandlers.chapterBoundary.postMessage(dir);
            }

            document.addEventListener('wheel', function(e) {
                if ((window.__ebPaginated && !window.__ebScrollMode) || cooldown) return;
                var delta = e.deltaY;
                var scrollable = document.body.scrollHeight - window.innerHeight;

                if (scrollable <= 5) {
                    if ((delta > 0 && boundaryDir < 0) || (delta < 0 && boundaryDir > 0)) {
                        boundaryAcc = 0;
                    }
                    boundaryAcc += delta;
                    boundaryDir = delta > 0 ? 1 : -1;
                    if (boundaryAcc > boundaryThreshold) fireBoundary('next');
                    else if (boundaryAcc < -boundaryThreshold) fireBoundary('prev');
                    return;
                }

                var atBottom = (window.scrollY >= scrollable - 2);
                var atTop = (window.scrollY <= 2);

                if (atBottom && delta > 0) {
                    if (boundaryDir !== 1) { boundaryAcc = 0; boundaryDir = 1; }
                    boundaryAcc += delta;
                    if (boundaryAcc > boundaryThreshold) fireBoundary('next');
                } else if (atTop && delta < 0) {
                    if (boundaryDir !== -1) { boundaryAcc = 0; boundaryDir = -1; }
                    boundaryAcc += delta;
                    if (boundaryAcc < -boundaryThreshold) fireBoundary('prev');
                } else {
                    boundaryAcc = 0;
                    boundaryDir = 0;
                }
            }, {passive: true});
        })();
        """

        // MARK: - Pagination JS (Calibre-style column layout)

        /// Paginated mode: CSS columns with scrollLeft navigation.
        /// `colsPerScreen` = 1 for single-page, 2 for two-page spread.
        /// Uses column-width (not column-count) for precise sizing like Calibre.
        private static func paginatedModeJS(colsPerScreen: Int) -> String { """
        (function() {
            var old = document.getElementById('__eb_pagination_style');
            if (old) old.remove();
            document.body.style.transform = '';

            var vpW = document.documentElement.clientWidth;
            var vpH = document.documentElement.clientHeight;
            var margin = 60;
            var blockMargin = 20;
            var gap = 80;
            var cols = \(colsPerScreen);
            var contentH = vpH - 2 * blockMargin;
            var usableW = vpW - 2 * margin;
            var colW = cols === 1 ? usableW : Math.floor((usableW - gap * (cols - 1)) / cols);
            var colAndGap = colW + gap;
            var pageScroll = colAndGap * cols;

            var style = document.createElement('style');
            style.id = '__eb_pagination_style';
            style.textContent =
                'html { height:100%!important; overflow:hidden!important; margin:0!important; padding:0!important; }' +
                'body { margin:0!important; padding:' + blockMargin + 'px ' + margin + 'px!important;' +
                ' height:' + contentH + 'px!important;' +
                ' column-width:' + colW + 'px!important; column-gap:' + gap + 'px!important;' +
                ' column-fill:auto!important; box-sizing:content-box!important;' +
                ' overflow-wrap:break-word!important; -webkit-margin-collapse:separate!important;' +
                ' overflow:visible!important; min-width:0!important; max-width:none!important; }' +
                'p,li,blockquote,h1,h2,h3,h4,h5,h6,figure,pre,table,dl,dt,dd { break-inside:avoid!important; }' +
                'img,svg,video { max-height:' + contentH + 'px!important; max-width:' + colW + 'px!important; break-inside:avoid!important; }';
            document.head.appendChild(style);

            window.__ebPaginated = true;
            window.__ebScrollMode = false;
            window.__ebCurrentPage = 0;

            requestAnimationFrame(function() {
                var totalCols = Math.max(1, Math.round(document.body.scrollWidth / colAndGap));
                window.__ebTotalPages = Math.max(1, Math.ceil(totalCols / cols));
                window.__ebPageSize = pageScroll;
                // Respect pending page (set by Swift before pagination for zero-flash backward nav)
                var startPage = 0;
                if (window.__ebPendingPage === -1) { startPage = window.__ebTotalPages - 1; }
                else if (window.__ebPendingPage > 0) { startPage = window.__ebPendingPage; }
                window.__ebPendingPage = undefined;
                window.__ebGoToPage(startPage);
            });

            window.__ebGoToPage = function(page) {
                if (page < 0) {
                    if (!window.__ebBoundaryCooldown) {
                        window.__ebBoundaryCooldown = true;
                        setTimeout(function(){ window.__ebBoundaryCooldown = false; }, 1500);
                        window.webkit.messageHandlers.chapterBoundary.postMessage('prev');
                    }
                    return;
                }
                if (page >= window.__ebTotalPages) {
                    if (!window.__ebBoundaryCooldown) {
                        window.__ebBoundaryCooldown = true;
                        setTimeout(function(){ window.__ebBoundaryCooldown = false; }, 1500);
                        window.webkit.messageHandlers.chapterBoundary.postMessage('next');
                    }
                    return;
                }
                window.__ebCurrentPage = page;
                var pos = page * window.__ebPageSize;
                var maxPos = document.body.scrollWidth - document.documentElement.clientWidth;
                if (maxPos > 0 && pos > maxPos) {
                    pos = Math.floor(maxPos / window.__ebPageSize) * window.__ebPageSize;
                }
                document.documentElement.scrollLeft = Math.max(0, pos);
                window.webkit.messageHandlers.paginationState.postMessage(
                    JSON.stringify({current: page, total: window.__ebTotalPages})
                );
            };

            if (!window.__ebKeyHandler) {
                window.__ebKeyHandler = true;
                document.addEventListener('keydown', function(e) {
                    if (!window.__ebPaginated) return;
                    if (e.key === 'ArrowRight' || e.key === 'ArrowDown') { e.preventDefault(); window.__ebGoToPage(window.__ebCurrentPage + 1); }
                    else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') { e.preventDefault(); window.__ebGoToPage(window.__ebCurrentPage - 1); }
                });
                var scrollAcc = 0;
                document.addEventListener('wheel', function(e) {
                    if (!window.__ebPaginated || window.__ebScrollMode) return;
                    e.preventDefault();
                    scrollAcc += e.deltaY;
                    if (scrollAcc > 120) { scrollAcc = 0; window.__ebGoToPage(window.__ebCurrentPage + 1); }
                    else if (scrollAcc < -120) { scrollAcc = 0; window.__ebGoToPage(window.__ebCurrentPage - 1); }
                }, {passive: false});
            }
        })();
        """ }

        /// Scroll mode: plain vertical scrolling through the entire book. No pagination.
        /// Chapter detection via IntersectionObserver on .eb-chapter divs.
        private static let scrollPaginationJS = """
        (function() {
            var old = document.getElementById('__eb_pagination_style');
            if (old) old.remove();
            document.body.style.transform = '';
            document.body.style.position = '';
            document.body.style.top = '';
            document.body.style.left = '';
            document.body.style.width = '';
            document.body.style.zIndex = '';
            document.body.style.boxShadow = '';
            document.documentElement.scrollLeft = 0;
            var oldSpacer = document.getElementById('__eb_spacer');
            if (oldSpacer) oldSpacer.remove();

            // Resolve relative resource URLs in combined chapter divs
            document.querySelectorAll('.eb-chapter[data-base]').forEach(function(ch) {
                var base = ch.dataset.base || '';
                if (!base) return;
                ch.querySelectorAll('[src]').forEach(function(el) {
                    var s = el.getAttribute('src');
                    if (s && !s.startsWith('http') && !s.startsWith('data:') && !s.startsWith('/')) {
                        el.setAttribute('src', base + s);
                    }
                });
                ch.querySelectorAll('link[href]').forEach(function(el) {
                    var h = el.getAttribute('href');
                    if (h && !h.startsWith('http') && !h.startsWith('#') && !h.startsWith('/')) {
                        el.setAttribute('href', base + h);
                    }
                });
            });

            var vpH = document.documentElement.clientHeight;
            var style = document.createElement('style');
            style.id = '__eb_pagination_style';
            style.textContent =
                'html { overflow-y:auto!important; overflow-x:hidden!important; margin:0!important; padding:0!important; }' +
                'body { margin:0!important; padding:20px 60px!important; overflow-wrap:break-word!important; }' +
                'html::-webkit-scrollbar { width:8px; }' +
                ' html::-webkit-scrollbar-thumb { background:rgba(128,128,128,0.3); border-radius:4px; }';
            document.head.appendChild(style);

            window.__ebPaginated = false;
            window.__ebScrollMode = true;
            window.__ebCurrentPage = 0;
            window.__ebPageSize = vpH;

            requestAnimationFrame(function() {
                window.__ebTotalPages = Math.max(1, Math.ceil(document.body.scrollHeight / vpH));
                window.webkit.messageHandlers.paginationState.postMessage(
                    JSON.stringify({current: 0, total: window.__ebTotalPages})
                );
            });

            // Track scroll for page counter and chapter detection
            var scrollDebounce;
            var lastChapter = -1;
            document.addEventListener('scroll', function() {
                if (!window.__ebScrollMode) return;
                clearTimeout(scrollDebounce);
                scrollDebounce = setTimeout(function() {
                    var page = Math.round(document.documentElement.scrollTop / vpH);
                    page = Math.max(0, Math.min(page, window.__ebTotalPages - 1));
                    if (page !== window.__ebCurrentPage) {
                        window.__ebCurrentPage = page;
                        window.webkit.messageHandlers.paginationState.postMessage(
                            JSON.stringify({current: page, total: window.__ebTotalPages})
                        );
                    }
                    var chapters = document.querySelectorAll('.eb-chapter');
                    var centerY = document.documentElement.scrollTop + vpH / 2;
                    for (var i = chapters.length - 1; i >= 0; i--) {
                        if (chapters[i].offsetTop <= centerY) {
                            if (i !== lastChapter) {
                                lastChapter = i;
                                window.webkit.messageHandlers.scrollPosition.postMessage(
                                    JSON.stringify({chapter: i, totalChapters: chapters.length})
                                );
                            }
                            break;
                        }
                    }
                }, 100);
            }, true);
        })();
        """

        /// JS to remove pagination and restore free scroll
        private static let removePaginationJS = """
        (function() {
            var old = document.getElementById('__eb_pagination_style');
            if (old) old.remove();
            var spacer = document.getElementById('__eb_spacer');
            if (spacer) spacer.remove();
            document.body.style.transform = '';
            document.body.style.position = '';
            document.body.style.top = '';
            document.body.style.left = '';
            document.body.style.width = '';
            document.body.style.zIndex = '';
            document.body.style.boxShadow = '';
            document.documentElement.scrollLeft = 0;
            window.__ebPaginated = false;
            window.__ebScrollMode = false;
            window.__ebCurrentPage = 0;
            window.__ebTotalPages = 0;
        })();
        """

        /// JS that injects theme colors and font size into the page.
        static func themeJS(theme: ReaderTheme, fontSize: Double) -> String {
            let css = theme.cssOverride.replacingOccurrences(of: "\n", with: " ")
            return """
            (function() {
                var old = document.getElementById('__eb_theme_style');
                if (old) old.remove();
                var style = document.createElement('style');
                style.id = '__eb_theme_style';
                style.textContent = '\(css) body { font-size: \(fontSize)px !important; line-height: 1.6 !important; }';
                document.head.appendChild(style);
            })();
            """
        }

        // MARK: - Annotation JavaScript

        /// JS that captures text selection with XPath anchors and sends to Swift.
        private static let annotationSelectionJS = """
        (function() {
            if (window.__ebAnnotationSetup) return;
            window.__ebAnnotationSetup = true;

            function getXPath(node) {
                if (node.nodeType === Node.TEXT_NODE) {
                    var parent = node.parentNode;
                    var textNodes = [];
                    for (var i = 0; i < parent.childNodes.length; i++) {
                        if (parent.childNodes[i].nodeType === Node.TEXT_NODE) textNodes.push(parent.childNodes[i]);
                    }
                    var idx = textNodes.indexOf(node) + 1;
                    return getXPath(parent) + '/text()[' + idx + ']';
                }
                if (node === document.body) return '/html/body';
                var parent = node.parentNode;
                var siblings = [];
                for (var i = 0; i < parent.childNodes.length; i++) {
                    if (parent.childNodes[i].nodeName === node.nodeName) siblings.push(parent.childNodes[i]);
                }
                var idx = siblings.indexOf(node) + 1;
                var tag = node.nodeName.toLowerCase();
                return getXPath(parent) + '/' + tag + '[' + idx + ']';
            }

            document.addEventListener('mouseup', function() {
                if (!window.__ebAnnotationActive) return;
                var sel = window.getSelection();
                if (!sel || sel.isCollapsed || !sel.toString().trim()) return;

                var range = sel.getRangeAt(0);
                var data = {
                    text: sel.toString(),
                    startXPath: getXPath(range.startContainer),
                    startOffset: range.startOffset,
                    endXPath: getXPath(range.endContainer),
                    endOffset: range.endOffset
                };
                window.webkit.messageHandlers.annotationSelection.postMessage(JSON.stringify(data));
                sel.removeAllRanges();
            });
        })();
        """

        /// JS to apply/remove annotation highlights in the DOM.
        static func applyAnnotationsJS(_ annotations: [[String: Any]]) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: annotations),
                  let json = String(data: data, encoding: .utf8) else {
                return ""
            }
            return """
            (function() {
                // Remove old app annotations
                document.querySelectorAll('mark[data-eb-annotation]').forEach(function(m) {
                    var parent = m.parentNode;
                    while (m.firstChild) parent.insertBefore(m.firstChild, m);
                    parent.removeChild(m);
                    parent.normalize();
                });

                function resolveXPath(xpath) {
                    try {
                        var result = document.evaluate(xpath, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
                        return result.singleNodeValue;
                    } catch(e) { return null; }
                }

                var annotations = \(json);
                annotations.forEach(function(ann) {
                    try {
                        var startNode = resolveXPath(ann.startXPath);
                        var endNode = resolveXPath(ann.endXPath);
                        if (!startNode || !endNode) return;

                        var range = document.createRange();
                        range.setStart(startNode, Math.min(ann.startOffset, startNode.length || 0));
                        range.setEnd(endNode, Math.min(ann.endOffset, endNode.length || 0));

                        var mark = document.createElement('mark');
                        mark.setAttribute('data-eb-annotation', ann.id);
                        mark.style.backgroundColor = ann.bgColor || 'rgba(255,255,0,0.35)';
                        if (ann.tool === 'underline') {
                            mark.style.backgroundColor = 'transparent';
                            mark.style.textDecoration = 'underline';
                            mark.style.textDecorationColor = ann.solidColor || 'rgb(255,204,0)';
                            mark.style.textDecorationThickness = '2px';
                        } else if (ann.tool === 'strikethrough') {
                            mark.style.backgroundColor = 'transparent';
                            mark.style.textDecoration = 'line-through';
                            mark.style.textDecorationColor = ann.solidColor || 'rgb(255,59,48)';
                            mark.style.textDecorationThickness = '2px';
                        }

                        range.surroundContents(mark);
                    } catch(e) { /* XPath may not match after reflow */ }
                });
            })();
            """
        }

        /// JS to set annotation mode active/inactive
        static func setAnnotationActiveJS(_ active: Bool) -> String {
            return "window.__ebAnnotationActive = \(active ? "true" : "false");"
        }

        private static func searchResultsJS(for query: String) -> String {
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            return """
            (function() {
                var query = '\(escaped)';
                var body = document.body.innerText;
                var lower = body.toLowerCase();
                var qLower = query.toLowerCase();
                var results = [];
                var pos = 0;
                while ((pos = lower.indexOf(qLower, pos)) !== -1) {
                    var before = body.substring(Math.max(0, pos - 30), pos);
                    var match = body.substring(pos, pos + query.length);
                    var after = body.substring(pos + query.length, Math.min(body.length, pos + query.length + 30));
                    results.push({context: '...' + before + match + after + '...', position: pos});
                    pos += query.length;
                }
                window.webkit.messageHandlers.searchResults.postMessage(
                    JSON.stringify({count: results.length, results: results})
                );
            })();
            """
        }

        // MARK: - View Mode

        func applyViewMode() {
            guard let webView else { return }
            let isEpub: Bool
            if case .epubChapter = content { isEpub = true } else { isEpub = false }

            switch viewMode {
            case .freeScroll:
                if isEpub {
                    webView.evaluateJavaScript(Self.scrollPaginationJS, completionHandler: nil)
                } else {
                    webView.evaluateJavaScript(Self.removePaginationJS, completionHandler: nil)
                }
            case .singlePage:
                webView.evaluateJavaScript(Self.paginatedModeJS(colsPerScreen: 1), completionHandler: nil)
            case .twoPage:
                webView.evaluateJavaScript(Self.paginatedModeJS(colsPerScreen: 2), completionHandler: nil)
            }
        }

        func applyTheme() {
            guard let webView else { return }
            let js = Self.themeJS(theme: currentTheme, fontSize: currentFontSize)
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        // MARK: - WKNavigationDelegate

        nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                let goingToLastPage = self.pendingStartAtEnd
                if goingToLastPage {
                    self.pendingStartAtEnd = false
                    // Hide body immediately to prevent flash of page 1
                    _ = try? await webView.evaluateJavaScript("document.body.style.visibility='hidden'; window.__ebPendingPage = -1;")
                }

                _ = try? await webView.evaluateJavaScript(Self.scrollTrackingJS)
                _ = try? await webView.evaluateJavaScript(Self.chapterBoundaryJS)
                _ = try? await webView.evaluateJavaScript(Self.annotationSelectionJS)

                // Apply theme and font size
                applyTheme()

                // Apply annotation mode state
                let isActive = annotationState?.activeTool?.isTextBased == true
                _ = try? await webView.evaluateJavaScript(Self.setAnnotationActiveJS(isActive))

                // Restore annotations
                applyAnnotations()

                // Apply pagination
                let isEpub: Bool
                if case .epubChapter = self.content { isEpub = true } else { isEpub = false }
                let needsPagination = viewMode != .freeScroll || isEpub

                if needsPagination {
                    try? await Task.sleep(for: .milliseconds(50))
                    applyViewMode()
                    // Show body after pagination has positioned to correct page
                    if goingToLastPage {
                        try? await Task.sleep(for: .milliseconds(100))
                        _ = try? await webView.evaluateJavaScript("document.body.style.visibility='visible';")
                    }
                } else if let fraction = content?.scrollFraction, fraction > 0 {
                    let js = "window.scrollTo(0, \(fraction) * (document.body.scrollHeight - window.innerHeight));"
                    try? await Task.sleep(for: .milliseconds(100))
                    _ = try? await webView.evaluateJavaScript(js)
                }

                // Resume pending find after cross-chapter navigation
                if pendingFindAfterNavigation, !lastFindQuery.isEmpty {
                    pendingFindAfterNavigation = false
                    try? await Task.sleep(for: .milliseconds(100))
                    let config = WKFindConfiguration()
                    config.wraps = true
                    config.caseSensitive = false
                    webView.find(lastFindQuery, configuration: config) { _ in }
                }
            }
        }

        func applyAnnotations() {
            guard let webView, let annotationState else { return }

            let chapterIndex: Int
            if case .epubChapter(_, _, let si, _, _) = content {
                chapterIndex = si
            } else {
                chapterIndex = 0
            }

            // Filter annotations for this chapter (including comment/freeText)
            let chapterAnnotations = annotationState.annotations.compactMap { ann -> [String: Any]? in
                guard let pos = ann.decodedPosition,
                      case .reflowable(let ci, let startXPath, let startOffset, let endXPath, let endOffset, _) = pos,
                      ci == chapterIndex,
                      ann.tool.isTextBased else { return nil }

                return [
                    "id": ann.id.uuidString,
                    "tool": ann.tool.rawValue,
                    "startXPath": startXPath,
                    "startOffset": startOffset,
                    "endXPath": endXPath,
                    "endOffset": endOffset,
                    "bgColor": ann.color.cssColor,
                    "solidColor": ann.color.cssSolidColor,
                ]
            }

            let js = Self.applyAnnotationsJS(chapterAnnotations)
            if !js.isEmpty {
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        // MARK: - WKScriptMessageHandler

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            MainActor.assumeIsolated {
                switch message.name {
                case "scrollPosition":
                    // Combined scroll mode sends JSON with chapter info
                    if let jsonString = message.body as? String,
                       let data = jsonString.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let chapter = json["chapter"] as? Int,
                       let totalChapters = json["totalChapters"] as? Int {
                        onChapterChange?(chapter, totalChapters)
                        return
                    }
                    // Normal scroll fraction
                    guard let f = message.body as? Double, f >= 0, let content else { return }
                    switch content {
                    case .epubChapter(_, _, let spineIndex, _, _):
                        onSavePosition?(ReadingPosition.epub(spineIndex: spineIndex, scrollFraction: f))
                    case .fb2HTML:
                        onSavePosition?(ReadingPosition.fb2(scrollFraction: f))
                    case .mobiHTML, .chmHTML:
                        onSavePosition?(ReadingPosition.webBased(scrollFraction: f))
                    }

                case "paginationState":
                    guard let jsonString = message.body as? String,
                          let data = jsonString.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let current = json["current"] as? Int,
                          let total = json["total"] as? Int else { return }
                    onPaginationChange?(current, total)

                case "searchResults":
                    guard let jsonString = message.body as? String,
                          let data = jsonString.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let count = json["count"] as? Int,
                          let rawResults = json["results"] as? [[String: Any]],
                          let searchState else { return }

                    let chapterLabel: String
                    if case .epubChapter(_, _, let si, _, _) = content {
                        chapterLabel = "Chapter \(si + 1)"
                    } else {
                        chapterLabel = "Document"
                    }

                    searchState.totalMatches = count
                    searchState.isSearching = false
                    searchState.results = rawResults.enumerated().map { (i, r) in
                        InBookSearchState.SearchMatch(
                            pageLabel: "\(chapterLabel), match \(i + 1)",
                            context: r["context"] as? String ?? "",
                            index: i
                        )
                    }

                    if count > 0 {
                        searchState.currentMatchIndex = 0
                        let config = WKFindConfiguration()
                        config.wraps = true
                        config.caseSensitive = false
                        webView?.find(lastFindQuery, configuration: config) { _ in }
                    }

                case "annotationSelection":
                    guard let jsonString = message.body as? String,
                          let data = jsonString.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let annotationState,
                          let tool = annotationState.activeTool,
                          tool.isTextBased,
                          let bookId else { return }

                    let text = json["text"] as? String ?? ""
                    let startXPath = json["startXPath"] as? String ?? ""
                    let startOffset = json["startOffset"] as? Int ?? 0
                    let endXPath = json["endXPath"] as? String ?? ""
                    let endOffset = json["endOffset"] as? Int ?? 0

                    guard !text.isEmpty, !startXPath.isEmpty else { return }

                    let chapterIndex: Int
                    if case .epubChapter(_, _, let si, _, _) = content {
                        chapterIndex = si
                    } else {
                        chapterIndex = 0
                    }

                    let position = AnnotationPosition.reflowable(
                        chapterIndex: chapterIndex,
                        startXPath: startXPath,
                        startOffset: startOffset,
                        endXPath: endXPath,
                        endOffset: endOffset,
                        selectedText: text
                    )

                    let annotation = Annotation(
                        bookId: bookId,
                        tool: tool,
                        color: annotationState.activeColor,
                        position: position,
                        selectedText: text
                    )

                    onAnnotationCreated?(annotation)

                    // Auto-open note editor for comment/freeText tools
                    if tool == .comment || tool == .freeText {
                        Task { @MainActor in
                            annotationState.selectedAnnotationID = annotation.id
                        }
                    }

                case "chapterBoundary":
                    guard let direction = message.body as? String,
                          case .epubChapter(_, _, let spineIndex, let total, _) = content else { return }
                    let newIndex: Int
                    if direction == "next" {
                        newIndex = spineIndex + 1
                    } else {
                        newIndex = spineIndex - 1
                    }
                    guard newIndex >= 0, newIndex < total else { return }
                    onChapterAdvance?(newIndex, direction == "prev")

                default:
                    break
                }
            }
        }

        // MARK: - Navigation

        /// Directly loads a new ePub spine item into the WKWebView, bypassing SwiftUI's update cycle.
        @objc func handleSpineNavigation(_ notification: Notification) {
            guard let spineIndex = notification.object as? Int,
                  let epubContent,
                  let webView,
                  spineIndex >= 0, spineIndex < epubContent.spine.count else { return }

            let startAtEnd = (notification.userInfo?["startAtEnd"] as? Bool) == true
            pendingStartAtEnd = startAtEnd

            let href = epubContent.spine[spineIndex].href
            let chapterURL = epubContent.opfDirectoryURL.appendingPathComponent(href)
            let baseURL = epubContent.extractedBaseURL

            content = .epubChapter(
                chapterURL: chapterURL,
                baseURL: baseURL,
                spineIndex: spineIndex,
                totalSpineItems: epubContent.spine.count,
                scrollFraction: startAtEnd ? 1.0 : 0
            )

            webView.loadFileURL(chapterURL, allowingReadAccessTo: baseURL)
            onChapterChange?(spineIndex, epubContent.spine.count)
        }

        @objc func handleNavigation(_ notification: Notification) {
            guard let target = notification.object as? WebNavigationTargetWrapper else { return }

            switch target.value {
            case .epubChapter(let spineIndex):
                if case .epubChapter(_, _, _, let total, _) = content {
                    onChapterChange?(spineIndex, total)
                }
            case .scrollToAnchor(let anchor):
                let js = "document.getElementById('\(anchor)')?.scrollIntoView({behavior: 'smooth'});"
                webView?.evaluateJavaScript(js, completionHandler: nil)
            case .scrollToFraction(let fraction):
                let js = "window.scrollTo(0, \(fraction) * (document.body.scrollHeight - window.innerHeight));"
                webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        // MARK: - Go To Page

        @objc func goToPage(_ notification: Notification) {
            guard let pageIndex = notification.object as? Int,
                  let webView else { return }
            webView.evaluateJavaScript(
                "if (window.__ebGoToPage) window.__ebGoToPage(\(pageIndex))",
                completionHandler: nil
            )
        }

        // MARK: - Annotation Refresh

        @objc func refreshAnnotations(_ notification: Notification) {
            applyAnnotations()
        }

        // MARK: - Search

        @objc func findInBook(_ notification: Notification) {
            guard let query = notification.object as? String,
                  !query.isEmpty,
                  let webView else { return }
            lastFindQuery = query

            // Cross-chapter search for ePub with multiple spine items
            if let epubContent, epubContent.spine.count > 1 {
                performCrossChapterSearch(query: query)
            } else {
                webView.evaluateJavaScript(Self.searchResultsJS(for: query), completionHandler: nil)
            }
        }

        /// Search across all ePub chapters, not just the one currently loaded.
        private func performCrossChapterSearch(query: String) {
            guard let epubContent, let searchState else { return }
            let queryLower = query.lowercased()

            var allResults: [InBookSearchState.SearchMatch] = []

            for (i, spineItem) in epubContent.spine.enumerated() {
                let chapterURL = epubContent.opfDirectoryURL.appendingPathComponent(spineItem.href)
                guard let data = try? Data(contentsOf: chapterURL),
                      let html = String(data: data, encoding: .utf8) else { continue }
                let text = Self.stripHTMLForSearch(html)
                let lower = text.lowercased()

                var searchStart = lower.startIndex
                var matchInChapter = 0
                while let range = lower.range(of: queryLower, range: searchStart..<lower.endIndex) {
                    let contextStart = text.index(range.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
                    let contextEnd = text.index(range.upperBound, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex
                    let context = "...\(text[contextStart..<contextEnd])..."

                    allResults.append(InBookSearchState.SearchMatch(
                        pageLabel: "Ch. \(i + 1), match \(matchInChapter + 1)",
                        context: context,
                        index: allResults.count,
                        chapterIndex: i
                    ))
                    matchInChapter += 1
                    searchStart = range.upperBound
                }
            }

            searchState.totalMatches = allResults.count
            searchState.isSearching = false
            searchState.results = allResults

            // Highlight matches in the current chapter
            if allResults.count > 0 {
                searchState.currentMatchIndex = 0
                let config = WKFindConfiguration()
                config.wraps = true
                config.caseSensitive = false
                webView?.find(query, configuration: config) { _ in }
            }
        }

        /// Simple HTML tag stripper for search text extraction.
        private static func stripHTMLForSearch(_ html: String) -> String {
            html.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        @objc func navigateToMatch(_ notification: Notification) {
            guard let request = notification.object as? FindNavigationRequest,
                  !lastFindQuery.isEmpty,
                  let webView else { return }

            // Check if the target match is in a different chapter
            if let targetChapter = request.chapterIndex {
                let currentSpine: Int?
                if case .epubChapter(_, _, let si, _, _) = content {
                    currentSpine = si
                } else {
                    currentSpine = nil
                }

                if let currentSpine, targetChapter != currentSpine {
                    // Navigate to the target chapter, then find after load
                    pendingFindAfterNavigation = true
                    NotificationCenter.default.post(
                        name: .ebookReaderNavigateToSpineIndex,
                        object: targetChapter
                    )
                    return
                }
            }

            let config = WKFindConfiguration()
            config.wraps = true
            config.caseSensitive = false
            config.backwards = (request.direction == .previous)
            webView.find(lastFindQuery, configuration: config) { _ in }
        }

        func saveCurrentPosition() {
            guard let content else { return }
            webView?.evaluateJavaScript(
                "window.scrollY / Math.max(1, document.body.scrollHeight - window.innerHeight)"
            ) { [weak self] result, _ in
                guard let self else { return }
                let fraction = result as? Double ?? 0
                switch content {
                case .epubChapter(_, _, let spineIndex, _, _):
                    onSavePosition?(ReadingPosition.epub(spineIndex: spineIndex, scrollFraction: fraction))
                case .fb2HTML:
                    onSavePosition?(ReadingPosition.fb2(scrollFraction: fraction))
                case .mobiHTML, .chmHTML:
                    onSavePosition?(ReadingPosition.webBased(scrollFraction: fraction))
                }
            }
        }
    }
}

/// Wrapper to pass WebNavigationTarget through NotificationCenter (which requires AnyObject).
class WebNavigationTargetWrapper: @unchecked Sendable {
    let value: WebNavigationTarget
    init(_ value: WebNavigationTarget) { self.value = value }
}

// MARK: - Weak Script Message Handler Proxy

/// Breaks the WKUserContentController → Coordinator strong-reference cycle.
/// WKUserContentController retains its message handlers, so using a weak proxy
/// prevents the coordinator (and its WKWebView) from leaking.
private class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - Custom Notification

extension Notification.Name {
    static let ebookReaderNavigateToWebContent = Notification.Name("ebookReaderNavigateToWebContent")
    static let ebookReaderNavigateToSpineIndex = Notification.Name("ebookReaderNavigateToSpineIndex")
}
