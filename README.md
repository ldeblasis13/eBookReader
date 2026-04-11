# eBookReader

A native macOS e-book reader built with SwiftUI and AppKit, supporting six formats with a unified library, full-text search, annotations, and tabbed reading.

## Features

### Library
- **Six formats**: PDF, ePub, FB2, Mobi, AZW3, CHM
- **Watched folders**: Add folders to auto-scan for books; FSEvents detects new/removed files in real time
- **Grid and list views** with lazy-loaded cover thumbnails
- **Collections and groups**: Organize books into named collections, nested under groups
- **Format filter and sort**: Filter by format, sort by title/author/date/size
- **Search**: Filename and metadata search with 300ms debounce; full-text search across book content via FTS5

### Reading
- **Tabbed interface**: Open multiple books simultaneously with a custom tab bar
- **PDF**: PDFKit rendering, table of contents, zoom, in-book Cmd+F search
- **Reflowable formats** (ePub, FB2, Mobi, AZW3, CHM): WKWebView rendering with chapter navigation and JavaScript bridge
- **Reading position**: Persisted per book, restored on relaunch
- **Themes**: Normal, sepia, and night modes — applied instantly across all open tabs
- **Font size**: Adjustable per book for reflowable formats; zoom for PDF

### Annotations
- **Highlight, underline, strikethrough** on both PDF and reflowable content
- **Shapes** (rectangle, circle, line, arrow) and **free text** for PDF
- **Comments** on any format
- **Annotation sidebar**: Browse, navigate to, and delete annotations per book
- Six preset highlight colors

### Quick Look
- **Spacebar** toggles a floating preview panel for the selected book
- Arrow keys navigate between books; Escape closes

### Performance
- File-based thumbnail cache (`~/Library/Caches/EBookReader/Thumbnails/`) — no BLOBs in the database
- FTS5 background indexing with progress indicator
- Tested against 100k+ book libraries

## Requirements

- macOS 14.0 or later
- Xcode 15 or later

## Dependencies

Managed via Swift Package Manager:

| Package | Version | Use |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.x | SQLite database + FTS5 |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.x | ePub extraction |

Third-party C libraries bundled in the project:
- **libmobi** — Mobi/AZW3 parsing
- **chmlib** — CHM parsing and content serving

## Building

```bash
git clone git@github.com:ldeblasis13/eBookReader.git
cd eBookReader
open EBookReader.xcodeproj
```

Xcode will resolve Swift Package Manager dependencies automatically. Build and run with Cmd+R.

## Architecture

```
EBookReader/
├── App/                    # AppState (@Observable), app entry point
├── Database/               # GRDB repositories, FTS5 manager, migrations
├── Models/                 # Book, Annotation, Collection, ReaderTab, Theme
├── Parsers/                # EPubParser, FB2Parser, MobiParser, CHMParser
├── Services/               # FolderScanner, FileWatcher, ThumbnailGenerator, MetadataExtractor
├── Utilities/              # Constants, FileTypeDetector
└── Views/
    ├── Library/            # LibraryView, BookGridItem, BookListRow
    ├── Reader/             # ReaderContainerView, PDFReaderView, WebReaderView, TOC
    ├── Sidebar/            # SidebarView, watched folder and collection items
    ├── Annotations/        # AnnotationToolbar, AnnotationListView
    ├── QuickLook/          # QuickLookPreviewView
    └── Search/             # SearchResultsView
```

**Key design decisions:**
- `AppState` uses the `@Observable` macro as the single source of truth — no view models
- `DatabasePool` in WAL mode for concurrent reads during background indexing
- All app data lives in `~/Library/Application Support/EBookReader/` and `~/Library/Caches/EBookReader/` — book files are never modified
- Security-scoped bookmarks for sandbox-safe persistent folder access

## Data Storage

| Location | Contents |
|---|---|
| `~/Library/Application Support/EBookReader/library.db` | Books, collections, annotations, FTS index |
| `~/Library/Caches/EBookReader/Thumbnails/` | Cover image cache (JPEG, one file per book) |
| `~/Library/Caches/EBookReader/EPubExtracted/` | Extracted ePub contents for WKWebView rendering |

The app **never writes to watched folders or book files**.

## License

MIT
