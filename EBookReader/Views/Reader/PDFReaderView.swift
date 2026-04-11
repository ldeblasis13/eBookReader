import PDFKit
import SwiftUI

/// Wraps PDFKit's PDFView in an NSViewRepresentable for SwiftUI.
struct PDFReaderView: NSViewRepresentable {
    let url: URL
    let initialPosition: ReadingPosition?
    var onPageChange: ((Int, Int) -> Void)? // (currentPage, totalPages)

    func makeCoordinator() -> Coordinator {
        Coordinator(onPageChange: onPageChange)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true

        if let document = PDFDocument(url: url) {
            pdfView.document = document

            // Restore reading position
            if case .pdf(let pageIndex, _) = initialPosition,
               pageIndex < document.pageCount,
               let page = document.page(at: pageIndex) {
                pdfView.go(to: page)
            }
        }

        context.coordinator.pdfView = pdfView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject {
        weak var pdfView: PDFView?
        var onPageChange: ((Int, Int) -> Void)?

        init(onPageChange: ((Int, Int) -> Void)?) {
            self.onPageChange = onPageChange
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let pdfView,
                  let document = pdfView.document,
                  let currentPage = pdfView.currentPage,
                  let pageIndex = document.index(for: currentPage) as Int? else {
                return
            }
            onPageChange?(pageIndex, document.pageCount)
        }
    }
}

// MARK: - PDFView helpers exposed to the container

@MainActor
extension PDFView {
    var currentPageIndex: Int? {
        guard let page = currentPage, let document else { return nil }
        return document.index(for: page)
    }

    func goToPage(at index: Int) {
        guard let document, index < document.pageCount,
              let page = document.page(at: index) else { return }
        go(to: page)
    }
}
