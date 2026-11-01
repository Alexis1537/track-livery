import AppKit
import QuartzCore
import UniformTypeIdentifiers
import UserNotifications

// The drop window: glow cards, a Siri-colour wave in the drop zone, a step log
// with the segmented progress bar under it, flowing lines along the bottom, and
// a batch report inside the drop zone (Added / Already
// there / Failed tiles, one line per track). Window 560 x 440, fixed.
//
// Visual ideas inspired by three designs on 21st.dev (no code taken; this is a
// native AppKit implementation): "Interactive Tech Stack Bento Grid with Hover
// Effects" by themeocean (glow cards, step log), "Sonic Waveform" by
// dhileepkumargm (flowing lines) and "Siri Wave" (the wave). See NOTICE.

// MARK: - palette

enum Palette {
    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    static let accent = rgb(0x2DD4BF)        // Pool
    static let cyan = rgb(0x22D3EE)
    static let window = rgb(0x07080D)
    static let face = rgb(0x0B0D15)
    static let text = rgb(0xF1F5F9)
    static let soft = rgb(0xCBD5E1)
    static let secondary = rgb(0x94A3B8)
    static let dim = rgb(0x475569)
    static let okMark = rgb(0x6EE7B7)
    static let goMark = rgb(0x5EEAD4)
    static let goText = rgb(0xA5B4C8)
    static let red = rgb(0xFB7185)
    static let redText = rgb(0xFDA4AF)
    /// Siri colours for the wave (ruled 1 Nov 2026).
    static let siri: [NSColor] = [rgb(0xFF9F43), rgb(0xFF5CA8), rgb(0x5AC8FA), rgb(0x34C759)]
}

private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                   color: NSColor = Palette.text, mono: Bool = false,
                   align: NSTextAlignment = .left) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.alignment = align
    l.lineBreakMode = .byTruncatingTail
    l.maximumNumberOfLines = 1
    l.cell?.truncatesLastVisibleLine = true
    return l
}

private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

// MARK: - track results

enum TrackResult { case added, replaced, kept, failed(String) }

struct TrackOutcome {
    let name: String
    let result: TrackResult
}

// MARK: - the window

final class DropWindow: NSObject {
    private let window: NSWindow
    private let content: DropContentView

    private let zone: GlowCardView
    private let art: GlowCardView
    private let listCard: GlowCardView
    private let trackList = TrackListView(frame: NSRect(x: 12, y: 44, width: 496, height: 134))
    private let listCount = label("", size: 11, weight: .medium, color: Palette.goMark, align: .right)
    private let listHint = label("", size: 11, color: Palette.secondary)
    private let listEmpty = label("Dropped files appear here, each with its genre.", size: 12, color: Palette.dim, align: .center)
    private let setAll = NSPopUpButton(frame: .zero, pullsDown: true)
    private let importButton = SettingsButton(title: "Import", action: {})
    private let batchPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let batchLabel = label("Genre", size: 11, color: Palette.secondary, align: .right)
    private var settingsWindow: SettingsWindowController?
    private let watcher = FolderWatcher()
    private let watchChip = WatchChipView(frame: NSRect(x: 0, y: 0, width: 150, height: 22))
    private let zoneTitle = label("Drop zone", size: 11.5, weight: .medium, color: Palette.soft)
    private let badge = BadgeView(frame: NSRect(x: 0, y: 0, width: 90, height: 16))

    private let idleView = NSView()
    private let idleWave = SiriWaveView(frame: NSRect(x: 0, y: 0, width: 276, height: 64))
    private let idleTitle = label("Drop your music downloads here", size: 16, weight: .semibold, align: .center)
    private let idleSub = label("or click to choose files", size: 12, color: Palette.secondary, align: .center)

    private let runView = NSView()
    private let runWave = SiriWaveView(frame: NSRect(x: 0, y: 0, width: 276, height: 48))
    private let runName = label("", size: 13, weight: .semibold)
    private let log = StepLogView(frame: NSRect(x: 0, y: 0, width: 276, height: 82))
    private let bar = SegmentBarView(frame: NSRect(x: 0, y: 0, width: 274, height: 4))

    private let resultView = NSView()

    private let artImage = NSImageView()
    private let artPlaceholder = NSView()
    private let artCaption = label("", size: 10.5, color: Palette.secondary, align: .center)

    private let statusLabel = label("Ready", size: 14, weight: .semibold, align: .center)
    private let sonic = SonicWaveView(frame: NSRect(x: 0, y: 6, width: 560, height: 50))

    private var animator: Timer?
    private var energyTarget: CGFloat = 0.12

    private var items: [TrackItem] = []
    private var current: Int?
    private var processing = false
    /// True while a track is being converted or more are queued: an update must not
    /// restart the app now (Sparkle asks via AppDelegate).
    var isBusy: Bool { processing || items.contains { $0.state == .waiting } }
    private var runner: PipelineRunner?
    private var batchTotal = 0
    private var batchIndex = 0
    private var outcomes: [TrackOutcome] = []
    private var currentName = ""
    private var sawArtwork = false
    private var sawImport = false
    private var keptFormat: String?
    private var notificationsAsked = false
    /// Testing only: TRACKLIVERY_NO_IMPORT=1 skips the final add to Music.
    private let importToMusic = ProcessInfo.processInfo.environment["TRACKLIVERY_NO_IMPORT"] == nil

    static let accent = Palette.accent
    static let secondary = Palette.secondary
    static let hairline = NSColor.white.withAlphaComponent(0.13)

    override init() {
        content = DropContentView(frame: NSRect(x: 0, y: 0, width: 560, height: 600))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // closing only hides it; the Dock icon brings it back
        zone = GlowCardView(frame: NSRect(x: 20, y: 323, width: 304, height: 185), tint: Palette.accent)
        art = GlowCardView(frame: NSRect(x: 340, y: 323, width: 200, height: 185), tint: Palette.cyan)
        listCard = GlowCardView(frame: NSRect(x: 20, y: 95, width: 520, height: 212), tint: Palette.accent)
        super.init()

        window.contentView = content
        window.title = "Track Livery"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden // the header row already shows the name
        window.isMovableByWindowBackground = true
        window.center()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.minSize = NSSize(width: 560, height: 600)
        window.maxSize = NSSize(width: 560, height: 600)
        window.appearance = NSAppearance(named: .darkAqua) // dark menus and pop-ups

        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = Palette.window.cgColor
        addWashes()
        buildHeader()

        content.addSubview(zone)
        content.addSubview(art)
        content.addSubview(listCard)
        buildZone()
        buildArt()
        buildList()

        statusLabel.frame = NSRect(x: 20, y: 63, width: 520, height: 22)
        content.addSubview(statusLabel)
        content.addSubview(sonic)

        content.onDrop = { [weak self] urls in self?.enqueue(urls: urls) }
        content.onPointer = { [weak self] p in self?.pointer(p) }
        zone.onClick = { [weak self] in
            guard let self = self, !self.processing,
                  !self.items.contains(where: { $0.state == .ready || $0.state == .waiting }) else { return }
            self.chooseFiles()
        }

        NotificationCenter.default.addObserver(forName: .prefsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.prefsChanged()
        }
        showIdle()
        prefsChanged()
        startAnimator()
    }

    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: building

    private func addWashes() {
        // two faint colour washes behind the cards
        let washes: [(CGPoint, CGSize, NSColor)] = [
            (CGPoint(x: 0.12, y: 1.0), CGSize(width: 0.6, height: 0.55), Palette.accent.withAlphaComponent(0.13)),
            (CGPoint(x: 1.0, y: 0.0), CGSize(width: 0.5, height: 0.5), Palette.rgb(0x818CF8, 0.10))]
        for (start, radius, color) in washes {
            let g = CAGradientLayer()
            g.type = .radial
            g.colors = [color.cgColor, color.withAlphaComponent(0).cgColor]
            g.startPoint = start
            g.endPoint = CGPoint(x: start.x + radius.width, y: start.y + radius.height)
            g.frame = content.bounds
            content.layer?.addSublayer(g)
        }
    }

    private func buildHeader() {
        let disc = DiscIconView(frame: NSRect(x: 20, y: 520, width: 26, height: 26))
        content.addSubview(disc)
        let name = label("Track Livery", size: 14.5, weight: .bold)
        name.frame = NSRect(x: 55, y: 523, width: 160, height: 20)
        content.addSubview(name)
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.1.0"
        let pill = PillView(text: "V\(version)")
        let w = pill.fittingWidth
        pill.frame = NSRect(x: 540 - w, y: 522, width: w, height: 22)
        content.addSubview(pill)
        let gear = NSButton(title: "", target: self, action: #selector(openSettings))
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        gear.isBordered = false
        gear.contentTintColor = Palette.soft
        gear.toolTip = "Settings (⌘,)"
        gear.frame = NSRect(x: 540 - w - 32, y: 521, width: 24, height: 24)
        content.addSubview(gear)
        watchChip.onToggle = { Prefs.watchEnabled.toggle() }
        content.addSubview(watchChip)
    }

    private func buildZone() {
        zoneTitle.frame = NSRect(x: 14, y: 157, width: 180, height: 16)
        zone.addSubview(zoneTitle)
        badge.frame = NSRect(x: 200, y: 157, width: 90, height: 16)
        badge.isHidden = true
        zone.addSubview(badge)

        for v in [idleView, runView, resultView] {
            v.frame = zone.bounds
            v.wantsLayer = true
            zone.addSubview(v)
        }
        idleWave.frame = NSRect(x: 14, y: 84, width: 276, height: 50)
        idleView.addSubview(idleWave)
        idleTitle.frame = NSRect(x: 14, y: 56, width: 276, height: 22)
        idleView.addSubview(idleTitle)
        idleSub.frame = NSRect(x: 14, y: 36, width: 276, height: 16)
        idleView.addSubview(idleSub)

        // same genre for the batch: a genre menu in the drop zone's title row
        batchPopup.controlSize = .small
        batchPopup.font = .systemFont(ofSize: 11)
        batchPopup.frame = NSRect(x: 130, y: 152, width: 160, height: 22)
        batchPopup.target = self
        batchPopup.action = #selector(batchGenrePicked)
        zone.addSubview(batchPopup)
        batchLabel.frame = NSRect(x: 88, y: 157, width: 40, height: 16)
        zone.addSubview(batchLabel)

        runWave.frame = NSRect(x: 14, y: 124, width: 276, height: 30)
        runView.addSubview(runWave)
        runName.frame = NSRect(x: 14, y: 104, width: 276, height: 18)
        runView.addSubview(runName)
        log.frame = NSRect(x: 14, y: 24, width: 276, height: 76)
        runView.addSubview(log)
        bar.frame = NSRect(x: 15, y: 10, width: 274, height: 4)
        runView.addSubview(bar)
    }

    private func buildArt() {
        let t = label("Cover art", size: 11.5, weight: .medium, color: Palette.soft)
        t.frame = NSRect(x: 14, y: 157, width: 150, height: 16)
        art.addSubview(t)

        artPlaceholder.frame = NSRect(x: 25, y: 22, width: 150, height: 130)
        artPlaceholder.wantsLayer = true
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: 44, y: 46, width: 62, height: 62), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.withAlphaComponent(0.14).cgColor
        ring.lineWidth = 1.5
        artPlaceholder.layer?.addSublayer(ring)
        let dot = CALayer()
        dot.frame = CGRect(x: 72, y: 74, width: 6, height: 6)
        dot.cornerRadius = 3
        dot.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        artPlaceholder.layer?.addSublayer(dot)
        let ph = label("Appears here", size: 12, color: Palette.dim, align: .center)
        ph.frame = NSRect(x: 0, y: 14, width: 150, height: 16)
        artPlaceholder.addSubview(ph)
        art.addSubview(artPlaceholder)

        artImage.frame = NSRect(x: 40, y: 30, width: 120, height: 120)
        artImage.imageScaling = .scaleProportionallyUpOrDown
        artImage.wantsLayer = true
        artImage.layer?.cornerRadius = 10
        artImage.layer?.masksToBounds = true
        artImage.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        artImage.layer?.borderWidth = 1
        artImage.isHidden = true
        art.addSubview(artImage)

        artCaption.frame = NSRect(x: 8, y: 9, width: 184, height: 14)
        art.addSubview(artCaption)
    }

    // MARK: views per state

    private func show(_ v: NSView) {
        for other in [idleView, runView, resultView] {
            let on = other === v
            if on { other.isHidden = false }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = reduceMotion ? 0.15 : 0.3
                other.animator().alphaValue = on ? 1 : 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }
            for other in [self.idleView, self.runView, self.resultView] where other !== v { other.isHidden = true }
        }
    }

    private func showIdle() {
        zoneTitle.stringValue = "Drop zone"
        idleTitle.stringValue = "Drop your music downloads here"
        idleSub.stringValue = Prefs.perTrack ? "or click to choose files" : "Genre: \(Prefs.batchGenre) · or click to choose"
        badge.isHidden = true
        idleView.alphaValue = 1
        runView.alphaValue = 0; runView.isHidden = true
        resultView.alphaValue = 0; resultView.isHidden = true
        statusLabel.attributedStringValue = statusText("Ready", nil)
        energyTarget = 0.12
    }

    private func statusText(_ main: String, _ rest: String?) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byTruncatingTail
        let s = NSMutableAttributedString(string: main, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: Palette.text, .paragraphStyle: p])
        if let rest = rest {
            s.append(NSAttributedString(string: " · " + rest, attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: Palette.secondary, .paragraphStyle: p]))
        }
        return s
    }

    private func setArtwork(_ image: NSImage?, caption: String) {
        guard let image = image else {
            artImage.isHidden = true
            artPlaceholder.isHidden = false
            artCaption.stringValue = ""
            return
        }
        artPlaceholder.isHidden = true
        artImage.image = image
        artImage.isHidden = false
        artCaption.stringValue = caption
        if !reduceMotion, let layer = artImage.layer {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.35
            layer.add(fade, forKey: "fade")
            let spring = CASpringAnimation(keyPath: "transform.scale")
            spring.fromValue = 0.9
            spring.toValue = 1
            spring.damping = 14
            spring.initialVelocity = 4
            spring.duration = spring.settlingDuration
            layer.add(spring, forKey: "pop")
        }
    }

    // MARK: animation

    /// Frames per second for the waves: smooth while converting, a gentle 12
    /// when idle, and nothing at all while the window cannot be seen (the app
    /// stays open in the Dock all day; 1.1.0 used ~23% of a core when idle).
    private var fps: Double = 0

    private func startAnimator() {
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                               queue: .main) { [weak self] _ in self?.updateFrameRate() }
        updateFrameRate()
    }

    private func updateFrameRate() {
        let visible = window.occlusionState.contains(.visible) && !window.isMiniaturized
        let want: Double = !visible ? 0 : (processing ? 60 : 12)
        guard want != fps else { return }
        fps = want
        animator?.invalidate()
        animator = nil
        guard want > 0 else { return }
        let t = Timer(timeInterval: 1.0 / want, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.2 / want
        RunLoop.main.add(t, forMode: .common)
        animator = t
    }

    private func tick() {
        let dt = CGFloat(1.0 / max(fps, 1))
        let still = reduceMotion
        for w in [idleWave, runWave] {
            w.energy += (energyTarget - w.energy) * min(1, dt * 3)
            if !still { w.time += dt * 1.2 }
        }
        sonic.energy += (energyTarget - sonic.energy) * min(1, dt * 3)
        if !still { sonic.time += dt * 1.2 }
        if !idleView.isHidden { idleWave.redraw() }
        if !runView.isHidden { runWave.redraw() }
        sonic.needsDisplay = true
    }

    private func pointer(_ p: NSPoint?) {
        zone.pointer(p.map { zone.convert($0, from: content) })
        art.pointer(p.map { art.convert($0, from: content) })
        listCard.pointer(p.map { listCard.convert($0, from: content) })
        sonic.pointer = p.map { sonic.convert($0, from: content) }
    }

    // MARK: - track list

    private func buildList() {
        let t = label("Tracks", size: 11.5, weight: .medium, color: Palette.soft)
        t.frame = NSRect(x: 14, y: 184, width: 150, height: 16)
        listCard.addSubview(t)
        listCount.frame = NSRect(x: 300, y: 184, width: 206, height: 16)
        listCard.addSubview(listCount)
        listEmpty.frame = NSRect(x: 14, y: 100, width: 492, height: 16)
        listCard.addSubview(listEmpty)
        trackList.onGenreChange = { [weak self] i, g in
            guard let self = self, i < self.items.count, self.items[i].editable else { return }
            self.items[i].genre = g
            self.trackList.refresh(i)
        }
        listCard.addSubview(trackList)
        listHint.frame = NSRect(x: 14, y: 15, width: 270, height: 15)
        listCard.addSubview(listHint)
        setAll.controlSize = .small
        setAll.font = .systemFont(ofSize: 11)
        setAll.frame = NSRect(x: 290, y: 10, width: 112, height: 24)
        setAll.target = self
        setAll.action = #selector(setAllPicked)
        listCard.addSubview(setAll)
        importButton.target = self
        importButton.action = #selector(importPressed)
        importButton.frame = NSRect(x: 408, y: 10, width: 98, height: 26)
        listCard.addSubview(importButton)
        refreshList(rebuild: true)
    }

    private func prefsChanged() {
        let genres = Prefs.genreMenu(including: [Prefs.batchGenre])
        batchPopup.removeAllItems()
        batchPopup.addItems(withTitles: genres)
        batchPopup.selectItem(withTitle: Prefs.batchGenre)
        setAll.removeAllItems()
        setAll.addItem(withTitle: "Set all to…")
        setAll.addItems(withTitles: Prefs.genres)
        trackList.genresEditable = Prefs.perTrack
        updateWatcher()
        if !processing && !items.contains(where: { $0.state == .ready }) { showIdle() }
        refreshList(rebuild: true)
    }

    private func refreshList(rebuild: Bool) {
        if rebuild { trackList.reload(items) } else { trackList.refreshAll() }
        listEmpty.isHidden = !items.isEmpty
        let done = items.filter { [.added, .kept, .failed].contains($0.state) }.count
        listCount.stringValue = items.isEmpty ? "" : "\(done) of \(items.count) done"
        let ready = items.filter { $0.state == .ready }.count
        let waiting = items.filter { $0.state == .waiting }.count
        importButton.isHidden = ready == 0
        importButton.attributedTitle = NSAttributedString(string: ready == 1 ? "Import 1 track" : "Import \(ready) tracks", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: Palette.rgb(0x04201B)])
        importButton.layer?.backgroundColor = Palette.accent.cgColor
        importButton.frame = NSRect(x: 506 - 112, y: 10, width: 112, height: 26)
        setAll.isHidden = !Prefs.perTrack || (ready + waiting) == 0
        setAll.frame.origin.x = importButton.isHidden ? 506 - 112 : 506 - 112 - 118
        if ready > 0 && items.contains(where: { $0.fromWatch && $0.state == .ready }) && Prefs.afterImport == "folder" && Prefs.backupFolder == nil {
            listHint.stringValue = "No backup folder chosen yet (see Settings)."
        } else if ready > 0 {
            listHint.stringValue = "Nothing starts until you press Import."
        } else if Prefs.perTrack && waiting > 0 {
            listHint.stringValue = "Change the genre of any track still waiting."
        } else if !Prefs.perTrack && processing {
            listHint.stringValue = "All tracks: \(Prefs.batchGenre)."
        } else {
            listHint.stringValue = ""
        }
        let showBatch = !Prefs.perTrack && !processing
        batchPopup.isHidden = !showBatch
        batchLabel.isHidden = !showBatch
    }

    @objc func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController() }
        settingsWindow?.refresh()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func batchGenrePicked() {
        if let g = batchPopup.titleOfSelectedItem { Prefs.batchGenre = g }
    }

    @objc private func setAllPicked() {
        guard let g = setAll.titleOfSelectedItem, g != "Set all to…" else { return }
        for item in items where item.editable { item.genre = g }
        setAll.selectItem(at: 0)
        refreshList(rebuild: false)
    }

    /// The notification's Import button.
    func importFromNotification() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        importPressed()
    }

    private func notifyArrivals(_ n: Int) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = "Track Livery"
        c.body = n == 1 ? "1 new download found in \(Prefs.watchFolder.lastPathComponent)" : "\(n) new downloads found in \(Prefs.watchFolder.lastPathComponent)"
        c.categoryIdentifier = "NEW_DOWNLOADS"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "new-downloads", content: c, trigger: nil)) { _ in }
    }

    /// After Music has the track: move the original download into the backup folder,
    /// or to the Bin (ruled: user-selected folder). The tagged copy beside it is a spare
    /// once Music holds its own copy, so it goes to the Bin, never to the backup
    ///, unless Music plays that very file.
    /// Keep everything: if the backup cannot be made, nothing is moved or binned
    /// and the row says where the download still is.
    private func afterImport(_ item: TrackItem) {
        guard importToMusic else { return }
        guard Prefs.afterImport != "leave" else { return }
        let fm = FileManager.default
        let spare: URL? = {
            guard let o = item.output,
                  o.standardizedFileURL != item.url.standardizedFileURL,
                  fm.fileExists(atPath: o.path),
                  !MusicImporter.libraryUses(o) else { return nil }
            return o
        }()

        func binSpare() {
            guard let o = spare else { return }
            watcher.ignore(o)
            NSWorkspace.shared.recycle([o]) { _, error in
                guard error != nil else { return }
                DispatchQueue.main.async {
                    item.message = "Couldn’t move the spare copy to the Bin: \((error!).localizedDescription)"
                    self.refreshList(rebuild: false)
                }
            }
        }

        // Already in Music: the original is never touched, only the spare may go.
        if item.state == .kept {
            binSpare()
            return
        }

        let originalMayGo = !MusicImporter.libraryUses(item.url)
        let stillThere = "The download is still in \(item.url.deletingLastPathComponent().lastPathComponent)."

        switch Prefs.afterImport {
        case "folder":
            guard let dest = Prefs.backupFolder else { return }
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            } catch {
                item.message = "Couldn’t back up to \(dest.lastPathComponent): \(error.localizedDescription). \(stillThere)"
                refreshList(rebuild: false)
                return
            }
            if originalMayGo {
                var target = dest.appendingPathComponent(item.url.lastPathComponent)
                var n = 2
                while fm.fileExists(atPath: target.path) {
                    target = dest.appendingPathComponent("\(item.url.deletingPathExtension().lastPathComponent) \(n).\(item.url.pathExtension)")
                    n += 1
                }
                watcher.ignore(target)
                do {
                    try fm.moveItem(at: item.url, to: target)
                } catch {
                    item.message = "Couldn’t back up to \(dest.lastPathComponent): \(error.localizedDescription). \(stillThere)"
                    refreshList(rebuild: false)
                    return
                }
            }
            binSpare()
        case "bin":
            var moving: [URL] = []
            if originalMayGo { moving.append(item.url) }
            if let o = spare {
                watcher.ignore(o)
                moving.append(o)
            }
            guard !moving.isEmpty else { return }
            NSWorkspace.shared.recycle(moving) { _, error in
                guard error != nil else { return }
                DispatchQueue.main.async {
                    item.message = "Couldn’t move to the Bin: \((error!).localizedDescription)"
                    self.refreshList(rebuild: false)
                }
            }
        default:
            break
        }
    }

    @objc private func importPressed() {
        for item in items where item.state == .ready { item.state = .waiting }
        refreshList(rebuild: false)
        startNextIfNeeded()
    }

    // MARK: - queue

    func enqueue(path: String) { enqueue(url: URL(fileURLWithPath: path)) }

    func enqueue(url: URL) { enqueue(urls: [url]) }

    // MARK: - watched folder

    private var watchKey = ""

    private func updateWatcher() {
        let folder = Prefs.watchFolder
        let skip = Prefs.afterImport == "folder" ? Prefs.backupFolder : nil
        let key = "\(Prefs.watchEnabled)|\(folder.path)|\(Prefs.watchSubfolders)|\(skip?.path ?? "")"
        let name = folder.lastPathComponent
        watchChip.set(on: Prefs.watchEnabled, folder: name)
        let w = watchChip.fittingWidth
        if let gear = content.subviews.first(where: { ($0 as? NSButton)?.toolTip == "Settings (⌘,)" }) {
            watchChip.frame = NSRect(x: gear.frame.minX - w - 8, y: 522, width: w, height: 22)
        }
        guard key != watchKey else { return }
        watchKey = key
        watcher.onNewFiles = { [weak self] urls in self?.arrived(urls) }
        if Prefs.watchEnabled {
            watcher.start(folder: folder, subfolders: Prefs.watchSubfolders, skip: skip)
        } else {
            watcher.stop()
        }
        if !processing && items.isEmpty { showIdle() }
    }

    /// New downloads: listed and waiting for Import; a notification asks (ruled).
    private func arrived(_ urls: [URL]) {
        let before = items.count
        enqueue(urls: urls, fromWatch: true)
        let added = items.count - before
        guard added > 0 else { return }
        let n = items.filter { $0.state == .ready }.count
        notifyArrivals(n)
    }

    private func plan(for url: URL, tags: SourceTags) -> [(kind: String, text: String)] {
        let ext = url.pathExtension.uppercased()
        let format: (String, String) = Converter.isCompressed(url)
            ? ("keep", Converter.formatName(url) == "Apple Lossless" ? "Lossless · keep" : "\(Converter.formatName(url)) · keep")
            : ("conv", "\(ext == "AIF" ? "AIFF" : ext) → ALAC")
        let f = ArtworkFetcher()
        let artist = tags.artist ?? PipelineRunner.parseArtist(url)
        let art: (String, String) = f.hasEmbeddedArt(url) ? ("art", "Art in file")
            : f.hasFolderArt(url, artist: artist, album: tags.album) ? ("art", "Cover in folder") : ("art", "Find art")
        return [format, art]
    }

    private func enqueue(urls: [URL]) { enqueue(urls: urls, fromWatch: false) }

    private func enqueue(urls: [URL], fromWatch: Bool) {
        let files = urls.filter { Converter.accepts($0) }
        guard !files.isEmpty else {
            statusLabel.attributedStringValue = statusText("That isn’t a WAV, AIFF, FLAC, MP3 or AAC file", nil)
            return
        }
        let busy = processing || items.contains { $0.state == .waiting || $0.state == .ready }
        if !busy {
            items = []
            batchTotal = 0
            batchIndex = 0
            outcomes = []
        }
        // per track (ruled A): files wait for Import, unless a batch is already running;
        // watched downloads always wait for Import (ruled: ask in a notification)
        let review = fromWatch || (Prefs.perTrack && !processing)
        for url in files {
            let tags = SourceTags.read(url)
            // the file's own tags beat the file name (Beatport writes ' as _ in file names)
            let fileName = (url.lastPathComponent as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: "'")
            let name = tags.artist.flatMap { a in tags.title.map { "\(a) — \($0)" } } ?? fileName
            let fileGenre = tags.genre
            let genre: String
            if Prefs.perTrack {
                genre = (Prefs.useFileGenre ? fileGenre : nil) ?? Prefs.defaultGenre
            } else {
                genre = Prefs.batchGenre
            }
            if items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL && $0.state != .failed }) { continue }
            let item = TrackItem(url: url, name: name, genre: genre, fileGenre: fileGenre, state: review ? .ready : .waiting)
            item.plan = plan(for: url, tags: tags)
            item.fromWatch = fromWatch
            items.append(item)
        }
        batchTotal += files.count
        refreshList(rebuild: true)
        if review && processing {
            refreshList(rebuild: true)
            return
        }
        if review {
            let n = items.filter { $0.state == .ready }.count
            zoneTitle.stringValue = fromWatch ? "New downloads" : "Ready to import"
            idleTitle.stringValue = fromWatch ? (n == 1 ? "1 new download" : "\(n) new downloads") : (n == 1 ? "1 file ready" : "\(n) files ready")
            idleSub.stringValue = fromWatch ? "Found in \(Prefs.watchFolder.lastPathComponent) · press Import" : "Check each genre in the list, then press Import"
            show(idleView)
            statusLabel.attributedStringValue = statusText(idleTitle.stringValue, "choose genres below")
            return
        }
        if processing { updateRunHeader() } // files from Finder or the Dock arrive one at a time
        startNextIfNeeded()
    }

    /// Opens a file picker that accepts several files at once.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.wav, .aiff, .mp3, .mpeg4Audio] + [UTType(filenameExtension: "flac")].compactMap { $0 }
        panel.message = "Choose one or more music downloads (WAV, AIFF, FLAC, MP3 or AAC)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.enqueue(urls: panel.urls)
        }
    }

    private func updateRunHeader() {
        badge.isHidden = false
        badge.text = batchTotal > 1 ? "\(batchIndex) of \(batchTotal)" : "Working"
        statusLabel.attributedStringValue = batchTotal > 1
            ? statusText("\(batchIndex) of \(batchTotal)", currentName)
            : statusText(currentName, nil)
    }

    private func startNextIfNeeded() {
        guard !processing, let index = items.firstIndex(where: { $0.state == .waiting }) else { return }
        let item = items[index]
        item.state = .running
        item.percent = 0
        current = index
        processing = true
        updateFrameRate()
        batchIndex += 1
        currentName = item.name
        sawArtwork = false
        sawImport = false
        keptFormat = nil
        if batchIndex == 1 { askForNotificationsOnce() }

        zoneTitle.stringValue = "Converting"
        runName.stringValue = currentName
        updateRunHeader()
        log.clear()
        log.add(.running, "Reading the file")
        bar.progress = 0
        setArtwork(nil, caption: "")
        energyTarget = 0.55
        show(runView)
        refreshList(rebuild: false)

        let runner = PipelineRunner()
        self.runner = runner
        runner.delegate = self
        runner.importToMusic = importToMusic
        runner.genre = item.genre
        runner.run(fileURL: item.url)
    }

    private func finish(_ outcome: TrackOutcome) {
        outcomes.append(outcome)
        if let i = current, i < items.count {
            switch outcome.result {
            case .added, .replaced: items[i].state = .added
            case .kept: items[i].state = .kept
            case .failed(let m): items[i].state = .failed; items[i].message = m
            }
            items[i].name = outcome.name
            if items[i].fromWatch, items[i].state == .added || items[i].state == .kept { afterImport(items[i]) }
        }
        current = nil
        processing = false
        energyTarget = 0.3
        // stay smooth for the next track; drop to idle pace only when the batch is over
        let more = items.contains { $0.state == .waiting }
        refreshList(rebuild: false)
        if !more { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.updateFrameRate() } }
        if !more {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showReport() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.startNextIfNeeded() }
        }
    }

    // MARK: - report (ruled design A)

    private func counts() -> (added: Int, kept: Int, failed: Int) {
        var a = 0, k = 0, f = 0
        for o in outcomes {
            switch o.result {
            case .added, .replaced: a += 1
            case .kept: k += 1
            case .failed: f += 1
            }
        }
        return (a, k, f)
    }

    private var needsPermission: Bool {
        outcomes.contains {
            if case .failed(let m) = $0.result { return m.contains("Automation") }
            return false
        }
    }

    private func headline() -> String {
        let n = outcomes.count, c = counts()
        if needsPermission && c.added == 0 && c.kept == 0 { return "Music didn’t accept the tracks" }
        if n == 1 {
            switch outcomes[0].result {
            case .added: return "Added to Music"
            case .replaced: return "Replaced the old copy in Music"
            case .kept: return "Already in your library"
            case .failed: return "Couldn’t add this track"
            }
        }
        if c.added == n { return "\(n) tracks added to Music" }
        if c.kept == n { return "All \(n) were already in your library" }
        return [c.added > 0 ? "\(c.added) added" : nil, c.kept > 0 ? "\(c.kept) already there" : nil,
                c.failed > 0 ? "\(c.failed) failed" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private func showReport() {
        guard !processing, !items.contains(where: { $0.state == .waiting }), !outcomes.isEmpty else { return }
        energyTarget = 0
        zoneTitle.stringValue = outcomes.count == 1 ? "Finished" : "Batch finished"
        badge.isHidden = true
        statusLabel.attributedStringValue = statusText("Ready", "drop more files to start a new batch")
        resultView.subviews.forEach { $0.removeFromSuperview() }
        if outcomes.count == 1 { buildSingleReport() } else { buildBatchReport() }
        show(resultView)
        notifyIfInBackground()
    }

    private func buildSingleReport() {
        let o = outcomes[0]
        let kind: ResultIcon.Kind
        var why: String? = nil
        switch o.result {
        case .added, .replaced: kind = .ok
        case .kept: kind = .kept
        case .failed(let m): kind = .bad; why = firstSentence(m)
        }
        resultView.addSubview(ResultIcon(frame: NSRect(x: 132, y: 100, width: 40, height: 40), kind: kind))
        let t = label(headline(), size: 15, weight: .semibold, align: .center)
        t.frame = NSRect(x: 14, y: 74, width: 276, height: 20)
        resultView.addSubview(t)
        let s = label(o.name, size: 11.5, color: Palette.secondary, align: .center)
        s.lineBreakMode = .byTruncatingMiddle
        s.frame = NSRect(x: 14, y: 56, width: 276, height: 15)
        resultView.addSubview(s)
        if let why = why {
            let w = label(why, size: 11, color: Palette.redText, align: .center)
            w.frame = NSRect(x: 14, y: 38, width: 276, height: 14)
            resultView.addSubview(w)
        }
        if needsPermission { addSettingsButton(y: 8, centered: true) }
    }

    private func buildBatchReport() {
        let c = counts()
        let tileW: CGFloat = (276 - 12) / 3
        let tiles = [(c.added, "Added"), (c.kept, "Already there"), (c.failed, "Failed")].enumerated().map { i, item in
            TileView(frame: NSRect(x: 14 + CGFloat(i) * (tileW + 6), y: 105, width: tileW, height: 46), value: item.0, caption: item.1)
        }
        tiles.forEach { resultView.addSubview($0); $0.countUp() }

        let permissionOnly = needsPermission && c.added == 0 && c.kept == 0
        let h = NSMutableAttributedString(string: headline(), attributes: [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Palette.text])
        if permissionOnly {
            h.append(NSAttributedString(string: " · Track Livery needs your permission", attributes: [
                .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Palette.secondary]))
        }
        let head = label("", size: 12.5, weight: .semibold)
        head.attributedStringValue = h
        head.lineBreakMode = .byTruncatingTail
        head.frame = NSRect(x: 14, y: 82, width: 276, height: 17)
        resultView.addSubview(head)

        var top: CGFloat = 106
        let maxRows = permissionOnly ? 2 : 3
        for (i, o) in outcomes.prefix(maxRows).enumerated() {
            let mark: StepLogView.Kind
            var why: String? = nil
            switch o.result {
            case .added, .replaced: mark = .ok
            case .kept: mark = .kept
            case .failed(let m): mark = .bad; if !permissionOnly { why = firstSentence(m) }
            }
            let row = StepLogView.row(mark, o.name, width: 276)
            row.frame.origin = NSPoint(x: 14, y: 185 - top - 17)
            resultView.addSubview(row)
            StepLogView.rise(row, delay: 0.2 + Double(i) * 0.08)
            top += 18
            if let why = why {
                let w = label(why, size: 10.5, color: Palette.redText)
                w.frame = NSRect(x: 31, y: 185 - top - 13, width: 259, height: 13)
                resultView.addSubview(w)
                top += 14
            }
        }
        if outcomes.count > maxRows {
            let more = label("+ \(outcomes.count - maxRows) more", size: 10.5, color: Palette.secondary)
            more.frame = NSRect(x: 31, y: 185 - top - 13, width: 200, height: 13)
            resultView.addSubview(more)
            top += 14
        }
        if needsPermission { addSettingsButton(y: max(10, 185 - top - 32), centered: false) }
    }

    private func addSettingsButton(y: CGFloat, centered: Bool) {
        let b = SettingsButton(title: "Open Settings…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity?Privacy_Automation")!)
        }
        let w: CGFloat = 118
        b.frame = NSRect(x: centered ? (304 - w) / 2 : 14, y: y, width: w, height: 26)
        resultView.addSubview(b)
    }

    private func firstSentence(_ s: String) -> String {
        if let r = s.range(of: ". ") { return String(s[..<r.lowerBound]) + "." }
        return s
    }

    // MARK: - notification (ruled: only when the window is not in front)

    private func askForNotificationsOnce() {
        guard !notificationsAsked, Bundle.main.bundleIdentifier != nil else { return }
        notificationsAsked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyIfInBackground() {
        guard !NSApp.isActive, Bundle.main.bundleIdentifier != nil else { return }
        let n = UNMutableNotificationContent()
        n.title = "Track Livery"
        n.body = headline()
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil)) { _ in }
    }
}

// MARK: - pipeline events -> step log

extension DropWindow: PipelineDelegate {
    private func step(_ completed: Int, _ fraction: Double = 0) -> Double {
        (Double(completed) + fraction) / Double(SegmentBarView.stepCount)
    }

    func pipelineEvent(_ event: PipelineEvent) {
        defer {
            // the running row in the track list shows the track's overall progress
            if let i = current, i < items.count, items[i].state == .running {
                items[i].percent = Int(bar.progress * 100)
                trackList.refresh(i)
            }
        }
        switch event {
        case .recognized(let artist, let title):
            currentName = artist.isEmpty ? title : "\(artist) — \(title)"
            runName.stringValue = currentName
            updateRunHeader()
            log.settle(.ok, "Read the file")
            log.add(.running, "Converting to Apple Lossless · 0%") // replaced at once for MP3/AAC
            bar.progress = step(1)
            energyTarget = 1
        case .converting(let p):
            log.updateRunning("Converting to Apple Lossless · \(Int(p * 100))%")
            bar.progress = step(1, p)
        case .keptFormat(let name):
            keptFormat = name
            log.settle(.ok, "Kept as \(name), no conversion")
            bar.progress = step(2)
        case .artwork(let data, let w, let h, let source, _, _, _):
            if keptFormat == nil { log.settle(.ok, "Converted to Apple Lossless") }
            sawArtwork = true
            let caption = "\(w) × \(h) px · \(source)"
            log.add(.ok, "Cover art \(w) × \(h) · \(source)")
            setArtwork(NSImage(data: data), caption: caption)
            bar.progress = step(3)
        case .tagging:
            if !sawArtwork {
                if keptFormat == nil { log.settle(.ok, "Converted to Apple Lossless") }
                log.add(.kept, "No cover art found")
            }
            log.add(.running, "Tags & packaging")
            bar.progress = step(3, 0.5)
            energyTarget = 0.6
        case .importing:
            sawImport = true
            log.settle(.ok, "Tagged: genre, cover, title, album")
            log.add(.running, "Adding to your Music library")
            bar.progress = step(4)
        case .done(let output, let replaced, let kept):
            if let i = current, i < items.count { items[i].output = output }
            watcher.ignore(output)
            if !sawImport {
                log.settle(.ok, "Tagged: genre, cover, title, album")
                log.add(.ok, "Saved as \(output.lastPathComponent)")
            } else if kept {
                log.settle(.kept, "Already in Music · kept your copy")
            } else {
                log.settle(.ok, replaced ? "Replaced the old copy in Music" : "Added to Music")
            }
            bar.progress = 1
            finish(TrackOutcome(name: currentName, result: kept ? .kept : replaced ? .replaced : .added))
        case .failed(let message):
            log.settle(.bad, firstLine(message))
            bar.tint = Palette.red
            energyTarget = 0.2
            finish(TrackOutcome(name: currentName, result: .failed(message)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.bar.tint = Palette.accent }
        }
    }

    private func firstLine(_ s: String) -> String {
        if let r = s.range(of: ". ") { return String(s[..<r.lowerBound]) }
        return s.hasSuffix(".") ? String(s.dropLast()) : s
    }
}

// MARK: - drop target: the whole window accepts WAV, AIFF and FLAC drops; also reports the pointer

final class DropContentView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onPointer: ((NSPoint?) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func mouseMoved(with event: NSEvent) { onPointer?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onPointer?(nil) }

    private func wavURLs(_ sender: NSDraggingInfo) -> [URL]? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        let wavs = urls.filter { Converter.accepts($0) }
        return wavs.isEmpty ? nil : wavs
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onPointer?(convert(sender.draggingLocation, from: nil))
        return wavURLs(sender) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onPointer?(convert(sender.draggingLocation, from: nil))
        return wavURLs(sender) != nil ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onPointer?(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onPointer?(nil)
        guard let urls = wavURLs(sender) else { return false }
        onDrop?(urls)
        return true
    }
}

// MARK: - glow card (idea inspired by the 21st.dev Bento grid)

final class GlowCardView: NSView {
    var onClick: (() -> Void)?
    private let edge = CAShapeLayer()
    private let glowHolder = CALayer()
    private let glow = CAGradientLayer()
    private let faceLayer = CALayer()
    private let spot = CAGradientLayer()
    private let grid = CAShapeLayer()
    private let gridMask = CAGradientLayer()
    private var lit = false

    init(frame: NSRect, tint: NSColor) {
        super.init(frame: frame)
        wantsLayer = true
        let r: CGFloat = 16
        let b = bounds

        edge.path = CGPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5), cornerWidth: r, cornerHeight: r, transform: nil)
        edge.fillColor = nil
        edge.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        edge.lineWidth = 1

        // bright edge following the pointer: a radial gradient masked to the border ring
        glowHolder.frame = b
        let ring = CAShapeLayer()
        ring.frame = b
        ring.path = edge.path
        ring.fillColor = nil
        ring.strokeColor = NSColor.black.cgColor
        ring.lineWidth = 1.5
        glowHolder.mask = ring
        glow.type = .radial
        glow.colors = [tint.withAlphaComponent(0.95).cgColor, tint.withAlphaComponent(0).cgColor]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.bounds = CGRect(x: 0, y: 0, width: 340, height: 340)
        glowHolder.addSublayer(glow)
        glowHolder.opacity = 0

        faceLayer.frame = b.insetBy(dx: 1, dy: 1)
        faceLayer.cornerRadius = r - 1
        faceLayer.backgroundColor = Palette.face.cgColor
        faceLayer.masksToBounds = true

        spot.type = .radial
        spot.colors = [tint.withAlphaComponent(0.14).cgColor, tint.withAlphaComponent(0).cgColor]
        spot.startPoint = CGPoint(x: 0.5, y: 0.5)
        spot.endPoint = CGPoint(x: 1, y: 1)
        spot.bounds = CGRect(x: 0, y: 0, width: 520, height: 520)
        spot.opacity = 0
        faceLayer.addSublayer(spot)

        let path = CGMutablePath()
        var x: CGFloat = 0
        while x < b.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: b.height)); x += 20 }
        var y: CGFloat = 0
        while y < b.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: b.width, y: y)); y += 20 }
        grid.path = path
        grid.strokeColor = NSColor.white.withAlphaComponent(0.08).cgColor
        grid.lineWidth = 1
        grid.frame = faceLayer.bounds
        gridMask.type = .radial
        gridMask.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        gridMask.startPoint = CGPoint(x: 0.5, y: 0.5)
        gridMask.endPoint = CGPoint(x: 1, y: 1)
        gridMask.bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        grid.mask = gridMask
        grid.opacity = 0
        faceLayer.addSublayer(grid)

        layer?.addSublayer(faceLayer)
        layer?.addSublayer(edge)
        layer?.addSublayer(glowHolder)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Pointer in this card's coordinates, or nil when it left the window.
    func pointer(_ p: NSPoint?) {
        let near = p.map { bounds.insetBy(dx: -40, dy: -40).contains($0) } ?? false
        if let p = p {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.position = p
            spot.position = CGPoint(x: p.x - 1, y: p.y - 1)
            gridMask.position = CGPoint(x: p.x - 1, y: p.y - 1)
            CATransaction.commit()
        }
        if near != lit {
            lit = near
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            for l in [glowHolder, spot, grid] as [CALayer] { l.opacity = near ? 1 : 0 }
            CATransaction.commit()
        }
    }

    override var mouseDownCanMoveWindow: Bool { onClick == nil }
    /// A click activating the window never opens the picker.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    private var pressPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        guard onClick != nil else { super.mouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        // only a press on the card's body, with the window already in front;
        // the title row (genre menu) and edges are ignored
        pressPoint = (window?.isKeyWindow == true && p.y < bounds.height - 34 && bounds.insetBy(dx: 8, dy: 8).contains(p)) ? p : nil
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressPoint = nil }
        guard let onClick = onClick, let start = pressPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - start.x, p.y - start.y) < 4 { onClick() } // a click, not a drag
    }
}

// MARK: - pulsing "2 of 4" badge

final class BadgeView: NSView {
    private let dot = CALayer()
    private let textField = label("", size: 11, weight: .medium, color: Palette.goMark, align: .right)
    var text: String {
        get { textField.stringValue }
        set { textField.stringValue = newValue; layoutText() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        textField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        addSubview(textField)
        dot.backgroundColor = Palette.accent.cgColor
        dot.cornerRadius = 3
        layer?.addSublayer(dot)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func layoutText() {
        let w = min(bounds.width - 12, ceil(textField.attributedStringValue.size().width) + 4)
        textField.frame = NSRect(x: bounds.width - w, y: 0, width: w, height: 16)
        dot.frame = CGRect(x: bounds.width - w - 11, y: 5, width: 6, height: 6)
    }
}

// MARK: - version pill (from the Sonic Waveform hero badge)

final class PillView: NSView {
    private let text: NSTextField
    var fittingWidth: CGFloat { ceil(text.attributedStringValue.size().width) + 40 }

    init(text t: String) {
        text = label(t, size: 10.5, weight: .semibold, color: Palette.soft)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = Palette.accent.withAlphaComponent(0.10).cgColor
        layer?.borderColor = Palette.accent.withAlphaComponent(0.22).cgColor
        layer?.borderWidth = 1
        addSubview(text)
        for (i, h) in [3.0, 6.0, 4.0, 2.0].enumerated() {
            let b = CALayer()
            b.backgroundColor = Palette.goMark.cgColor
            b.cornerRadius = 0.75
            b.frame = CGRect(x: 10 + CGFloat(i) * 3, y: 11 - h / 2, width: 1.5, height: h)
            layer?.addSublayer(b)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func layout() {
        super.layout()
        text.frame = NSRect(x: 26, y: 3, width: bounds.width - 30, height: 15)
    }
}

/// Small vinyl mark for the header row.
final class DiscIconView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = Palette.accent.cgColor
        ring.lineWidth = 1.7
        layer?.addSublayer(ring)
        let dot = CALayer()
        dot.backgroundColor = Palette.accent.cgColor
        dot.cornerRadius = 2.6
        dot.frame = CGRect(x: (bounds.width - 5.2) / 2, y: (bounds.height - 5.2) / 2, width: 5.2, height: 5.2)
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

// MARK: - Siri-colour wave (idea inspired by 21st.dev "Siri Wave")

final class SiriWaveView: NSView {
    var energy: CGFloat = 0.12
    var time: CGFloat = 0
    private let lobes = SiriLobesView()
    private let core = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        lobes.frame = bounds.insetBy(dx: 0, dy: -10)
        lobes.owner = self
        lobes.wantsLayer = true
        lobes.layerUsesCoreImageFilters = true
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 7]) { lobes.layer?.filters = [blur] }
        addSubview(lobes)
        core.startPoint = CGPoint(x: 0, y: 0.5)
        core.endPoint = CGPoint(x: 1, y: 0.5)
        core.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.8).cgColor,
                       NSColor.white.withAlphaComponent(0).cgColor]
        core.locations = [0.2, 0.5, 0.8]
        layer?.addSublayer(core)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func redraw() {
        lobes.needsDisplay = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = 2 + energy * 3
        core.frame = CGRect(x: 0, y: bounds.midY - h / 2, width: bounds.width, height: h)
        core.opacity = Float(0.45 + energy * 0.5)
        CATransaction.commit()
    }
}

final class SiriLobesView: NSView {
    weak var owner: SiriWaveView?

    override func draw(_ dirtyRect: NSRect) {
        guard let owner = owner, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, mid = bounds.midY
        let amp = (0.06 + owner.energy * 0.94) * (bounds.height - 20) * 0.42
        ctx.setBlendMode(.plusLighter)
        let cs = CGColorSpaceCreateDeviceRGB()
        for (i, color) in Palette.siri.enumerated() {
            let ph = owner.time * (1.1 + CGFloat(i) * 0.35) + CGFloat(i) * 1.7
            let f = 1.2 + CGFloat(i) * 0.45
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: mid))
            var x: CGFloat = 0
            while x <= w {
                let u = x / w, env = pow(sin(.pi * u), 2.2)
                path.addLine(to: CGPoint(x: x, y: mid + env * amp * (0.55 + 0.45 * sin(u * f * 6 + ph))))
                x += 3
            }
            x = w
            while x >= 0 {
                let u = x / w, env = pow(sin(.pi * u), 2.2)
                path.addLine(to: CGPoint(x: x, y: mid - env * amp * (0.55 + 0.45 * sin(u * f * 6 + ph + 1.3))))
                x -= 3
            }
            path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            if let g = CGGradient(colorsSpace: cs, colors: [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0.6).cgColor,
                                                           color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.5, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: w, y: 0), options: [])
            }
            ctx.restoreGState()
        }
    }
}

// MARK: - flowing lines along the bottom (idea inspired by 21st.dev "Sonic Waveform")

final class SonicWaveView: NSView {
    var energy: CGFloat = 0.12
    var time: CGFloat = 0
    var pointer: NSPoint?

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let mid = bounds.midY, lines = 20, segs = 70
        let ampK = 0.35 + energy * 0.9
        let sy = bounds.height / 66
        ctx.setLineWidth(0.65)
        for i in 0..<lines {
            let inten = sin(CGFloat(i) / CGFloat(lines) * .pi)
            ctx.setStrokeColor(NSColor(srgbRed: 0, green: 1, blue: 0.753, alpha: inten * 0.42).cgColor)
            ctx.beginPath()
            for j in 0...segs {
                let jj = CGFloat(j)
                let x = 20 + jj / CGFloat(segs) * 520
                var me: CGFloat = 0
                if let ptr = pointer { me = max(0, 1 - hypot(x - ptr.x, mid - ptr.y) / 140) }
                let noise = sin(jj * 0.1 + time + CGFloat(i) * 0.2) * 5 * ampK
                let spike = cos(jj * 0.2 + time + CGFloat(i) * 0.1) * sin(jj * 0.05 + time) * 11 * ampK
                let edge = sin(.pi * jj / CGFloat(segs))
                let y = mid + (noise + spike * (1 + me * 2)) * sy * edge
                if j == 0 { ctx.move(to: CGPoint(x: x, y: y)) } else { ctx.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.strokePath()
        }
    }
}

// MARK: - step log (idea inspired by the 21st.dev Bento grid terminal card)

final class StepLogView: NSView {
    enum Kind { case ok, running, kept, bad }
    private var rows: [NSView] = []
    private var running: NSTextField?
    private let cursor = CALayer()
    private let maxRows = 4

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.05).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 9
        cursor.backgroundColor = Palette.goMark.cgColor
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0
        blink.duration = 0.5
        blink.autoreverses = true
        blink.repeatCount = .infinity
        cursor.add(blink, forKey: "blink")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func colors(_ k: Kind) -> (mark: String, markColor: NSColor, textColor: NSColor) {
        switch k {
        case .ok: return ("✓", Palette.okMark, Palette.soft)
        case .running: return ("›", Palette.goMark, Palette.goText)
        case .kept: return ("=", Palette.secondary, Palette.soft)
        case .bad: return ("✗", Palette.red, Palette.redText)
        }
    }

    static func row(_ k: Kind, _ text: String, width: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 17))
        v.wantsLayer = true
        let c = colors(k)
        let m = label(c.mark, size: 11, weight: .semibold, color: c.markColor, mono: true, align: .center)
        m.frame = NSRect(x: 0, y: 0, width: 12, height: 15)
        m.identifier = NSUserInterfaceItemIdentifier("mark")
        let t = label(text, size: 11, color: c.textColor, mono: true)
        t.frame = NSRect(x: 17, y: 0, width: width - 17, height: 15)
        t.identifier = NSUserInterfaceItemIdentifier("text")
        v.addSubview(m)
        v.addSubview(t)
        return v
    }

    static func rise(_ v: NSView, delay: Double) {
        guard let l = v.layer, !reduceMotion else { return }
        let begin = CACurrentMediaTime() + delay
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = begin
        fade.duration = 0.3
        fade.fillMode = .backwards
        let move = CASpringAnimation(keyPath: "transform.translation.y")
        move.fromValue = -6
        move.toValue = 0
        move.damping = 15
        move.beginTime = begin
        move.duration = move.settlingDuration
        move.fillMode = .backwards
        l.add(fade, forKey: "fade")
        l.add(move, forKey: "rise")
    }

    private func field(_ row: NSView, _ id: String) -> NSTextField? {
        row.subviews.first { $0.identifier?.rawValue == id } as? NSTextField
    }

    func clear() {
        rows.forEach { $0.removeFromSuperview() }
        rows.removeAll()
        running = nil
        cursor.removeFromSuperlayer()
    }

    func add(_ k: Kind, _ text: String) {
        let r = StepLogView.row(k, text, width: bounds.width - 18)
        addSubview(r)
        rows.append(r)
        if rows.count > maxRows { rows.removeFirst().removeFromSuperview() }
        relayout()
        StepLogView.rise(r, delay: 0)
        running = k == .running ? field(r, "text") : nil
        placeCursor()
    }

    /// Turns the running line into a finished one (or adds a line if none is running).
    func settle(_ k: Kind, _ text: String) {
        guard let r = rows.last, running != nil else { add(k, text); return }
        let c = StepLogView.colors(k)
        if let m = field(r, "mark") { m.stringValue = c.mark; m.textColor = c.markColor }
        if let t = field(r, "text") { t.stringValue = text; t.textColor = c.textColor }
        running = nil
        placeCursor()
    }

    func updateRunning(_ text: String) {
        guard let t = running else { return }
        t.stringValue = text
        placeCursor()
    }

    private func relayout() {
        var top: CGFloat = 7
        for r in rows {
            r.frame.origin = NSPoint(x: 9, y: bounds.height - top - 17)
            top += 17
        }
    }

    private func placeCursor() {
        cursor.removeFromSuperlayer()
        guard let t = running, let row = t.superview else { return }
        let w = min(t.bounds.width - 8, ceil(t.attributedStringValue.size().width))
        let p = convert(NSPoint(x: t.frame.minX + w + 4, y: t.frame.minY + 2), from: row)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursor.frame = CGRect(x: p.x, y: p.y, width: 6, height: 11)
        layer?.addSublayer(cursor)
        CATransaction.commit()
    }
}

// MARK: - segmented progress bar, inside the drop zone (ruled 1 Nov 2026)

final class SegmentBarView: NSView {
    static let stepCount = 5
    private var segs: [(track: CALayer, fill: CALayer)] = []
    var tint: NSColor = Palette.accent {
        didSet { segs.forEach { $0.fill.backgroundColor = tint.cgColor; $0.fill.shadowColor = tint.cgColor } }
    }
    var progress: Double = 0 { didSet { layoutFill() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<SegmentBarView.stepCount {
            let t = CALayer()
            t.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            t.cornerRadius = 2
            let f = CALayer()
            f.backgroundColor = Palette.accent.cgColor
            f.cornerRadius = 2
            f.shadowColor = Palette.accent.cgColor
            f.shadowOpacity = 0.6
            f.shadowRadius = 4
            f.shadowOffset = .zero
            t.addSublayer(f)
            layer?.addSublayer(t)
            segs.append((t, f))
        }
        layoutFill()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func layoutFill() {
        let n = CGFloat(SegmentBarView.stepCount), gap: CGFloat = 4
        let w = (bounds.width - gap * (n - 1)) / n
        for (i, s) in segs.enumerated() {
            s.track.frame = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
            let k = max(0, min(1, progress * Double(n) - Double(i)))
            s.fill.frame = CGRect(x: 0, y: 0, width: w * CGFloat(k), height: bounds.height)
        }
    }
}

// MARK: - report pieces

final class TileView: NSView {
    private let number: NSTextField
    private let value: Int

    init(frame: NSRect, value: Int, caption: String) {
        self.value = value
        number = label("0", size: 20, weight: .semibold, color: value == 0 ? Palette.dim : Palette.text)
        number.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.025).cgColor
        number.frame = NSRect(x: 8, y: 18, width: frame.width - 12, height: 24)
        addSubview(number)
        let c = label(caption, size: 10.5, color: Palette.secondary)
        c.frame = NSRect(x: 8, y: 4, width: frame.width - 12, height: 13)
        addSubview(c)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func countUp() {
        guard value > 0, !reduceMotion else { number.stringValue = "\(value)"; return }
        let start = Date()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let k = min(1, Date().timeIntervalSince(start) / 0.6)
            self.number.stringValue = "\(Int((Double(self.value) * (1 - pow(1 - k, 3))).rounded()))"
            if k >= 1 { t.invalidate() }
        }
        RunLoop.main.add(t, forMode: .common)
    }
}

final class ResultIcon: NSView {
    enum Kind { case ok, kept, bad }

    init(frame: NSRect, kind: Kind) {
        super.init(frame: frame)
        wantsLayer = true
        let color = kind == .bad ? Palette.red : Palette.accent
        let disc = CAShapeLayer()
        disc.path = CGPath(ellipseIn: bounds, transform: nil)
        disc.fillColor = color.withAlphaComponent(0.14).cgColor
        layer?.addSublayer(disc)
        let s = bounds.width / 30
        let p = CGMutablePath()
        switch kind {
        case .ok:
            p.move(to: CGPoint(x: 9 * s, y: 14.5 * s)); p.addLine(to: CGPoint(x: 13.2 * s, y: 10.3 * s)); p.addLine(to: CGPoint(x: 21.5 * s, y: 19 * s))
        case .kept:
            p.move(to: CGPoint(x: 10 * s, y: 17 * s)); p.addLine(to: CGPoint(x: 20 * s, y: 17 * s))
            p.move(to: CGPoint(x: 10 * s, y: 13 * s)); p.addLine(to: CGPoint(x: 20 * s, y: 13 * s))
        case .bad:
            p.move(to: CGPoint(x: 11 * s, y: 11 * s)); p.addLine(to: CGPoint(x: 19 * s, y: 19 * s))
            p.move(to: CGPoint(x: 19 * s, y: 11 * s)); p.addLine(to: CGPoint(x: 11 * s, y: 19 * s))
        }
        let mark = CAShapeLayer()
        mark.path = p
        mark.fillColor = nil
        mark.strokeColor = color.cgColor
        mark.lineWidth = 2.4
        mark.lineCap = .round
        mark.lineJoin = .round
        layer?.addSublayer(mark)
        if !reduceMotion {
            // the mark draws itself
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 0.45
            draw.beginTime = CACurrentMediaTime() + 0.1
            draw.fillMode = .backwards
            draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.7, 0.2, 1)
            mark.add(draw, forKey: "draw")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

final class SettingsButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        handler = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Palette.accent.withAlphaComponent(0.35).cgColor
        layer?.backgroundColor = Palette.accent.withAlphaComponent(0.12).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: Palette.rgb(0xCCFBF1)])
        target = self
        self.action = #selector(fire)
    }

    @objc private func fire() { handler?() }
}

// MARK: - "Watching Downloads" switch in the header

final class WatchChipView: NSView {
    var onToggle: (() -> Void)?
    private let dot = CALayer()
    private let text = label("", size: 10.5, weight: .semibold, color: Palette.secondary)
    private var on = false
    var fittingWidth: CGFloat { ceil(text.attributedStringValue.size().width) + 30 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        addSubview(text)
        dot.cornerRadius = 3
        layer?.addSublayer(dot)
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")
        toolTip = "Click to pause or resume watching"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func set(on: Bool, folder: String) {
        self.on = on
        text.stringValue = on ? "Watching \(folder)" : "Not watching"
        text.textColor = on ? Palette.rgb(0xCCFBF1) : Palette.secondary
        layer?.borderColor = (on ? Palette.accent.withAlphaComponent(0.35) : NSColor.white.withAlphaComponent(0.12)).cgColor
        layer?.backgroundColor = (on ? Palette.accent.withAlphaComponent(0.08) : NSColor.clear).cgColor
        dot.backgroundColor = (on ? Palette.accent : Palette.dim).cgColor
        dot.speed = on ? 1 : 0
        needsLayout = true
    }

    override func layout() {
        super.layout()
        dot.frame = CGRect(x: 10, y: (bounds.height - 6) / 2, width: 6, height: 6)
        text.frame = NSRect(x: 21, y: 3, width: bounds.width - 25, height: 15)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onToggle?() }
    }
}
