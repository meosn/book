import SwiftUI
import PDFKit
import GoogleGenerativeAI
import Combine
internal import UniformTypeIdentifiers

struct TranslatedPage: Identifiable, Codable, Comparable {
    let id: Int
    var translatedText: String
    var status: PageStatus = .loading
    
    enum PageStatus: String, Codable {
        case loading, success, error
    }
    
    static func < (lhs: TranslatedPage, rhs: TranslatedPage) -> Bool { lhs.id < rhs.id }
}

@MainActor
class BookViewModel: ObservableObject {
    private let apiKey = "API_KEY" // <--- ВСТАВЬТЕ КЛЮЧ
    
    @Published var translatedPages: [TranslatedPage] = []
    @Published var progress: Double = 0
    @Published var isTranslating = false
    @Published var currentBookName: String = ""
    @Published var errorCount: Int = 0
    
    private var model: GenerativeModel?
    private var pdfDocument: PDFDocument?
    private let saveFolder = "SavedTranslations"

    init() {
        self.model = GenerativeModel(name: "gemini-flash-latest", apiKey: apiKey)
        createDirectory()
    }
    
    func loadBook(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        
        guard let document = PDFDocument(url: url) else { return }
        self.pdfDocument = document
        self.currentBookName = url.lastPathComponent
        
        if !loadLocalData(for: currentBookName) {
            self.translatedPages = []
        }
        
        updateStats()
        if translatedPages.count < document.pageCount || errorCount > 0 {
            startTranslating()
        }
    }

    func regenerateSinglePage(index: Int) {
        guard let doc = pdfDocument else { return }
        guard let pageText = doc.page(at: index)?.string else { return }
        
        if let idx = translatedPages.firstIndex(where: { $0.id == index }) {
            translatedPages[idx].status = .loading
        }
        
        Task {
            let result = await processSinglePage(index: index, text: pageText)
            if let page = result {
                self.translatedPages.removeAll(where: { $0.id == index })
                self.translatedPages.append(page)
                self.translatedPages.sort()
                saveLocalData()
                updateStats()
            }
        }
    }

    func regenerateBook() {
        isTranslating = false
        let url = getURL(for: currentBookName)
        try? FileManager.default.removeItem(at: url)
        self.translatedPages = []
        self.progress = 0
        self.errorCount = 0
        startTranslating()
    }
    
    func startTranslating() {
        guard let doc = pdfDocument, !isTranslating else { return }
        isTranslating = true
        
        Task {
            let total = doc.pageCount
            for i in 0..<total {
                if !isTranslating { break }
                if let existing = translatedPages.first(where: { $0.id == i }), existing.status == .success { continue }
                
                guard let pageText = doc.page(at: i)?.string else { continue }
                let result = await processSinglePage(index: i, text: pageText)
                
                if let page = result {
                    self.translatedPages.removeAll(where: { $0.id == i })
                    self.translatedPages.append(page)
                    self.translatedPages.sort()
                    saveLocalData()
                    updateStats()
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            isTranslating = false
        }
    }
    
    private func processSinglePage(index: Int, text: String) async -> TranslatedPage? {
        var engContext = ""
        var rusContext = ""
        if index > 0 {
            engContext = pdfDocument?.page(at: index-1)?.string?.suffix(350).description ?? ""
            rusContext = translatedPages.first(where: { $0.id == index-1 })?.translatedText.suffix(350).description ?? ""
        }
        
        let result = await translateWithAI(text: text, engContext: engContext, rusContext: rusContext, pageNum: index + 1)
        
        if let translatedText = result {
            let cleanedText = cleanResponse(translatedText)
            return TranslatedPage(id: index, translatedText: cleanedText, status: .success)
        } else {
            return TranslatedPage(id: index, translatedText: "⚠️ Ошибка. Попробуйте обновить страницу вручную.", status: .error)
        }
    }
    
    private func translateWithAI(text: String, engContext: String, rusContext: String, pageNum: Int) async -> String? {
        guard let model = model else { return nil }
        
        let prompt = """
        SYSTEM INSTRUCTION: You are a professional translator for psychology literature. 
        Translate the text provided between [START] and [END] tags.
        
        CONTINUITY:
        Previous English ended: "\(engContext)"
        Previous Russian ended: "\(rusContext)"
        
        STRICT RULES:
        1. OUTPUT ONLY the Russian translation.
        2. NEVER include labels like "STRICT RULES", "TERMINOLOGY", or "CURRENT TEXT".
        3. NEVER include the English source text in your response.
        4. Self = 'Самость'.
        5. Connect to the previous Russian context seamlessly without repetitions or dots.
        6. Start titles with '# '.
        
        [START]
        \(text)
        [END]
        """
        
        do {
            let response = try await model.generateContent(prompt)
            return response.text
        } catch {
            return nil
        }
    }

    private func cleanResponse(_ text: String) -> String {
        var cleaned = text
        let junk = [
            "STRICT RULES:", "TERMINOLOGY:", "SEAMLESS FLOW:", "NO TAGS:", "NO METADATA:", "NO WRAPPERS:", "HEADERS:",
            "CURRENT TEXT TO TRANSLATE:", "TRANSLATION:", "Russian translation:", "[START]", "[END]", "<blockquote>", "</blockquote>"
        ]
        for word in junk {
            cleaned = cleaned.replacingOccurrences(of: word, with: "", options: [.caseInsensitive, .regularExpression])
        }
        
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("...") {
            return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }
    
    private func updateStats() {
        guard let doc = pdfDocument else { return }
        let success = translatedPages.filter { $0.status == .success }.count
        self.progress = Double(success) / Double(doc.pageCount)
        self.errorCount = translatedPages.filter { $0.status == .error }.count
    }
    
    private func saveLocalData() {
        guard !currentBookName.isEmpty else { return }
        if let data = try? JSONEncoder().encode(translatedPages) {
            try? data.write(to: getURL(for: currentBookName))
        }
    }
    
    private func loadLocalData(for name: String) -> Bool {
        let url = getURL(for: name)
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([TranslatedPage].self, from: data) {
            self.translatedPages = saved.sorted()
            return true
        }
        return false
    }
    
    private func getURL(for name: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(saveFolder).appendingPathComponent(name + ".json")
    }
    
    private func createDirectory() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folderURL = docs.appendingPathComponent(saveFolder)
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }
    
    func exportPDF() -> URL? {
        let pdfDoc = PDFDocument()
        let rect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let sorted = translatedPages.filter { $0.status == .success }.sorted()
        
        for (i, page) in sorted.enumerated() {
            let renderer = UIGraphicsImageRenderer(size: rect.size)
            let img = renderer.image { ctx in
                UIColor.white.setFill(); ctx.fill(rect)
                var y: CGFloat = 60
                let lines = page.translatedText.components(separatedBy: .newlines)
                for line in lines {
                    let isHeader = line.hasPrefix("#")
                    let clean = line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
                    if clean.isEmpty { y += 15; continue }
                    let attr: [NSAttributedString.Key: Any] = [
                        .font: isHeader ? UIFont.boldSystemFont(ofSize: 22) : UIFont.systemFont(ofSize: 14),
                        .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineSpacing = 6; return p }()
                    ]
                    let str = NSAttributedString(string: clean, attributes: attr)
                    let h = str.boundingRect(with: CGSize(width: 495, height: 10000), options: .usesLineFragmentOrigin, context: nil).height
                    str.draw(in: CGRect(x: 50, y: y, width: 495, height: h))
                    y += h + (isHeader ? 20 : 10)
                    if y > 780 { break }
                }
            }
            if let pdfPage = PDFPage(image: img) { pdfDoc.insert(pdfPage, at: i) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Psychology_Final.pdf")
        return pdfDoc.write(to: url) ? url : nil
    }
}

struct ContentView: View {
    @StateObject var vm = BookViewModel()
    @State private var showFilePicker = false
    @State private var showResetAlert = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !vm.currentBookName.isEmpty {
                    VStack(spacing: 6) {
                        ProgressView(value: vm.progress).tint(.blue)
                        HStack {
                            Text("\(Int(vm.progress * 100))% переведено").font(.caption2).bold()
                            Spacer()
                            if vm.isTranslating { Text("Идет перевод...").font(.caption2).italic().foregroundColor(.orange) }
                        }
                    }.padding().background(Color(.secondarySystemBackground))
                }
                
                if vm.translatedPages.isEmpty && !vm.isTranslating {
                    VStack(spacing: 20) {
                        Image(systemName: "brain.head.profile").font(.system(size: 60)).foregroundColor(.blue.opacity(0.5))
                        Button("Выбрать PDF книгу") { showFilePicker = true }.buttonStyle(.borderedProminent).controlSize(.large)
                    }.frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 30) {
                            ForEach(vm.translatedPages) { page in
                                PageDetailView(page: page) {
                                    vm.regenerateSinglePage(index: page.id)
                                }
                            }
                        }.padding()
                    }
                }
            }
            .navigationTitle("AI Reader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 15) {
                        if !vm.translatedPages.isEmpty {
                            Menu {
                                ShareLink(item: vm.exportPDF() ?? URL(string: "about:blank")!) {
                                    Label("Сохранить PDF", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) { showResetAlert = true } label: {
                                    Label("Начать заново", systemImage: "arrow.clockwise")
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                        Button { showFilePicker = true } label: { Image(systemName: "plus") }
                    }
                }
            }
            .alert("Начать заново?", isPresented: $showResetAlert) {
                Button("Отмена", role: .cancel) { }
                Button("Да, начать заново", role: .destructive) { vm.regenerateBook() }
            } message: { Text("Весь текущий перевод этой книги будет удален.") }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.pdf]) { res in
                if case .success(let url) = res { vm.loadBook(url: url) }
            }
        }.navigationViewStyle(.stack)
    }
}

struct PageDetailView: View {
    let page: TranslatedPage
    let onRegenerate: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("СТРАНИЦА \(page.id + 1)").font(.caption2).bold().foregroundColor(.secondary)
                Spacer()
                if page.status != .loading {
                    Button(action: onRegenerate) {
                        Label("Обновить", systemImage: "arrow.clockwise").font(.caption2)
                    }.buttonStyle(.borderless)
                }
            }.frame(maxWidth: .infinity)
            
            if page.status == .loading {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else {
                let lines = page.translatedText.components(separatedBy: .newlines)
                ForEach(0..<lines.count, id: \.self) { i in
                    let line = lines[i]
                    if line.hasPrefix("#") {
                        Text(line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces))
                            .font(.system(.title2, design: .serif)).bold().padding(.vertical, 4)
                    } else if !line.isEmpty {
                        Text(line).font(.system(.body, design: .serif)).lineSpacing(7)
                    }
                }
            }
            Divider().padding(.top, 10)
        }
    }
}
