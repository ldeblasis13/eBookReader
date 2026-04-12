# eBookReader

A native macOS e-book reader built with SwiftUI and AppKit, supporting six formats with a unified library, AI-powered semantic search, and a built-in chat assistant.

## Features

### Library
- **Six formats**: PDF, ePub, FB2, Mobi, AZW3, CHM
- **Watched folders**: Add folders to auto-scan for books; FSEvents detects new/removed files in real time
- **Grid and list views** with lazy-loaded cover thumbnails
- **Collections and groups**: Organize books into named collections, nested under groups
- **Format filter and sort**: Filter by format, sort by title/author/date/size
- **Full-text search**: FTS5 keyword search across book content with semantic vector reranking

### Reading
- **Tabbed interface**: Open multiple books simultaneously with a custom tab bar
- **PDF**: PDFKit rendering, table of contents, zoom, in-book Cmd+F search
- **ePub**: Entire book rendered as a single document — seamless page-by-page navigation with book-wide page counter
- **Reflowable formats** (FB2, Mobi, AZW3, CHM): WKWebView rendering with chapter navigation
- **Three view modes**: Scroll (continuous vertical), single page, and two-page spread
- **Reading position**: Persisted per book, restored on relaunch
- **Themes**: Normal, sepia, and night modes
- **Font size**: Adjustable per book for reflowable formats; zoom for PDF

### AI-Powered Search & Chat
- **Local LLM**: Gemma 4 E2B (~1.5GB) runs entirely on-device via llama.cpp with Metal GPU acceleration
- **Semantic search**: all-MiniLM-L6-v2 embedding model generates vector embeddings for all book content; hybrid search combines FTS5 keywords with vector similarity
- **Chat assistant**: Ask questions about your books via the AI chat panel (sparkle icon). RAG pipeline retrieves relevant excerpts and generates answers with source citations
- **Book references**: Chat responses include clickable "Open" buttons linking to the source book
- **Scoped by collection**: Chat searches whichever collection is selected in the sidebar
- **Models download automatically** on first launch (~1.6GB total); progress shown in library and Settings

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
- File-based thumbnail cache — no BLOBs in the database
- FTS5 + embedding background indexing with progress indicators
- Tested against 100k+ book libraries

## Requirements

- macOS 14.0 or later
- Xcode 15 or later (for building from source)
- Apple Silicon recommended (Metal GPU used for LLM inference)

## Dependencies

Managed via Swift Package Manager:

| Package | Version | Use |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 7.x | SQLite database + FTS5 |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 0.9.x | ePub extraction |

Bundled C/C++ libraries:
- **[llama.cpp](https://github.com/ggml-org/llama.cpp)** — LLM and embedding inference with Metal GPU acceleration
- Prebuilt static libraries for arm64 macOS

Downloaded on first launch:
- **all-MiniLM-L6-v2** (~80MB) — sentence embedding model
- **Gemma 4 E2B** (~1.5GB) — language model for chat

## Installation

Download the latest DMG from [Releases](https://github.com/ldeblasis13/eBookReader/releases), open it, and drag EBookReader to your Applications folder.

On first launch, right-click the app → **Open** (macOS requires this for apps outside the App Store).

## Building from Source

Requires Xcode 15+ and CMake (for llama.cpp compilation).

**From the terminal:**
```bash
git clone --recursive git@github.com:ldeblasis13/eBookReader.git
cd eBookReader

# Build the app
make build

# Or build and install directly to /Applications
make install

# Or build a distributable DMG
make dmg
```

**From Xcode:**
```bash
git clone --recursive git@github.com:ldeblasis13/eBookReader.git
cd eBookReader
open EBookReader.xcodeproj
```
Build and run with Cmd+R. SPM dependencies resolve automatically.

## Architecture

```
EBookReader/
├── App/                    # AppState (@Observable), app entry point
├── Database/               # GRDB repositories, FTS5 manager, text chunk repo, migrations
├── Models/                 # Book, Annotation, Collection, ChatMessage, TextChunk, ModelInfo
├── Parsers/                # EPubParser, FB2Parser, MobiParser, CHMParser
├── Services/               # LLMEngine, EmbeddingManager, ChatManager, HybridSearchManager,
│                           # ModelDownloadManager, FolderScanner, FileWatcher, ThumbnailGenerator
├── Utilities/              # Constants, FileTypeDetector
├── Vendor/                 # llama.cpp (git submodule) + prebuilt static libraries
└── Views/
    ├── Chat/               # ChatPanelView (AI chat sidebar)
    ├── Library/            # LibraryView, BookGridItem, BookListRow
    ├── Reader/             # ReaderContainerView, PDFReaderView, WebReaderView, TOC
    ├── Sidebar/            # SidebarView, watched folder and collection items
    ├── Annotations/        # AnnotationToolbar, AnnotationListView
    ├── QuickLook/          # QuickLookPreviewView
    └── Search/             # SearchResultsView
```

**Key design decisions:**
- `AppState` uses the `@Observable` macro as the single source of truth
- `DatabasePool` in WAL mode for concurrent reads during background indexing
- ePub rendered as a combined HTML document (all chapters in one file) for seamless pagination
- All app data lives in `~/Library/Application Support/EBookReader/` and `~/Library/Caches/EBookReader/` — book files are never modified
- LLM and embedding models stored in `~/Library/Application Support/EBookReader/Models/`

## Data Storage

| Location | Contents |
|---|---|
| `~/Library/Application Support/EBookReader/library.db` | Books, collections, annotations, FTS index, text chunks + embeddings, model status |
| `~/Library/Application Support/EBookReader/Models/` | Downloaded LLM and embedding model files |
| `~/Library/Caches/EBookReader/Thumbnails/` | Cover image cache (JPEG, one file per book) |
| `~/Library/Caches/EBookReader/EPubExtracted/` | Extracted ePub contents for WKWebView rendering |

The app **never writes to watched folders or book files**.

## License

MIT
