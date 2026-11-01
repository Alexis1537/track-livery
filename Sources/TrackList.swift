import AppKit

/// One dropped file in the track list.
final class TrackItem {
    enum State { case ready, waiting, running, added, kept, failed }
    let url: URL
    var name: String
    var genre: String
    let fileGenre: String?
    var state: State
    var percent = 0
    var message: String?
    /// What the app found: format chip and cover-art chip (watch-wow).
    var plan: [(kind: String, text: String)] = []
    /// Arrived through the watched folder (moved to the backup folder after import).
    var fromWatch = false
    /// The finished file saved beside the original.
    var output: URL?

    init(url: URL, name: String, genre: String, fileGenre: String?, state: State) {
        self.url = url
        self.name = name
        self.genre = genre
        self.fileGenre = fileGenre
        self.state = state
    }

    var editable: Bool { state == .ready || state == .waiting }
}

/// The scrolling list of tracks, each with its own genre menu.
final class TrackListView: NSView {
    var onGenreChange: ((Int, String) -> Void)?
    /// When false (same genre for the batch) the menus are shown but locked.
    var genresEditable = true
    private let scroll = NSScrollView()
    private let doc = FlippedView()
    private var items: [TrackItem] = []
    private var rows: [TrackRowView] = []
    private let rowHeight: CGFloat = 24

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = doc
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func reload(_ items: [TrackItem]) {
        let fresh = items.count > self.items.count ? self.items.count : items.count
        self.items = items
        rows.forEach { $0.removeFromSuperview() }
        rows = items.enumerated().map { i, item in
            let r = TrackRowView(frame: NSRect(x: 0, y: CGFloat(i) * (rowHeight + 2), width: bounds.width - 16, height: rowHeight))
            r.configure(item, editable: genresEditable && item.editable)
            r.onGenre = { [weak self] g in self?.onGenreChange?(i, g) }
            doc.addSubview(r)
            if i >= fresh { StepLogView.rise(r, delay: Double(i - fresh) * 0.08) }
            return r
        }
        doc.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height, CGFloat(items.count) * (rowHeight + 2)))
    }

    /// Updates one row in place (progress ticks), without rebuilding the list.
    func refresh(_ index: Int) {
        guard index < rows.count, index < items.count else { return }
        rows[index].configure(items[index], editable: genresEditable && items[index].editable)
        if items[index].state == .running {
            // scroll by whole rows so no row is cut in half at the top
            let step = rowHeight + 2
            let visibleRows = max(1, Int(scroll.contentSize.height / step))
            let firstRow = max(0, index - visibleRows + 2)
            let y = min(CGFloat(firstRow) * step, max(0, doc.frame.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func refreshAll() { for i in rows.indices { refresh(i) } }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class TrackRowView: NSView {
    var onGenre: ((String) -> Void)?
    private let mark = NSTextField(labelWithString: "·")
    private let name = NSTextField(labelWithString: "")
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(labelWithString: "")
    private let chip1 = NSTextField(labelWithString: "")
    private let chip2 = NSTextField(labelWithString: "")
    private var lastGenres: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        mark.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        mark.alignment = .center
        mark.frame = NSRect(x: 6, y: 4, width: 14, height: 16)
        name.font = .systemFont(ofSize: 12)
        name.textColor = Palette.text
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 26, y: 4, width: frame.width - 26 - 116 - 66 - 8, height: 16)
        for c in [chip1, chip2] {
            c.font = .systemFont(ofSize: 9.5, weight: .semibold)
            c.alignment = .center
            c.wantsLayer = true
            c.layer?.cornerRadius = 4
            addSubview(c)
        }
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.frame = NSRect(x: frame.width - 66 - 116, y: 1, width: 112, height: 22)
        popup.target = self
        popup.action = #selector(picked)
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.alignment = .right
        status.frame = NSRect(x: frame.width - 66, y: 4, width: 60, height: 16)
        for v in [mark, name, popup, status] { addSubview(v) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(_ item: TrackItem, editable: Bool) {
        name.stringValue = item.name
        // chips sit between the name and the genre menu, each as wide as its text
        var right = popup.frame.minX - 6
        let widths = item.plan.map { ceil(($0.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold)]).width) + 10 }
        for (i, c) in [chip1, chip2].enumerated().reversed() where i < widths.count {
            c.frame = NSRect(x: right - widths[i], y: 5, width: widths[i], height: 14)
            right -= widths[i] + 4
        }
        name.frame.size.width = max(60, right - 4 - name.frame.minX)
        for (i, c) in [chip1, chip2].enumerated() {
            guard i < item.plan.count else { c.isHidden = true; continue }
            let (kind, text) = item.plan[i]
            c.isHidden = false
            c.stringValue = text
            let color: NSColor = kind == "conv" ? Palette.accent : kind == "keep" ? Palette.rgb(0x818CF8) : Palette.rgb(0xFBBF24)
            c.textColor = kind == "conv" ? Palette.rgb(0x99F6E4) : kind == "keep" ? Palette.rgb(0xC7D2FE) : Palette.rgb(0xFDE68A)
            c.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
            c.toolTip = text
        }
        let genres = Prefs.genreMenu(including: [item.genre, item.fileGenre ?? ""])
        if genres != lastGenres {
            popup.removeAllItems()
            popup.addItems(withTitles: genres)
            lastGenres = genres
        }
        popup.selectItem(withTitle: item.genre)
        popup.isEnabled = editable
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor
        layer?.borderWidth = 0
        switch item.state {
        case .ready: mark.stringValue = "·"; mark.textColor = Palette.dim; status.stringValue = "Ready"; status.textColor = Palette.secondary
        case .waiting: mark.stringValue = "·"; mark.textColor = Palette.dim; status.stringValue = "Waiting"; status.textColor = Palette.secondary
        case .running:
            mark.stringValue = "›"; mark.textColor = Palette.goMark
            status.stringValue = "\(item.percent)%"; status.textColor = Palette.goMark
            layer?.borderWidth = 1
            layer?.borderColor = Palette.accent.withAlphaComponent(0.25).cgColor
        case .added: mark.stringValue = "✓"; mark.textColor = Palette.okMark; status.stringValue = "Added"; status.textColor = Palette.secondary
        case .kept: mark.stringValue = "="; mark.textColor = Palette.secondary; status.stringValue = "Already there"; status.textColor = Palette.secondary
        case .failed: mark.stringValue = "✗"; mark.textColor = Palette.red; status.stringValue = "Failed"; status.textColor = Palette.red
        }
        toolTip = item.message
    }

    @objc private func picked() { if let g = popup.titleOfSelectedItem { onGenre?(g) } }
}
