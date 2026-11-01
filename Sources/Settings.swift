import AppKit

// Settings: genre for the
// whole batch or per track, a default genre, starting from the file's own
// genre, the genre list, and tidy capitals for titles and albums.

extension Notification.Name {
    static let prefsChanged = Notification.Name("TrackLiveryPrefsChanged")
}

enum Prefs {
    private static let d = UserDefaults.standard
    private static func changed() { NotificationCenter.default.post(name: .prefsChanged, object: nil) }

    static let starterGenres = ["Dance", "House", "Tech House", "Deep House", "Melodic House & Techno", "Afro House",
                                "Nu Disco / Disco", "Indie Dance", "Techno", "Drum & Bass", "Pop", "Electronica"]

    /// true: choose a genre for each track; false: one genre for the whole batch.
    static var perTrack: Bool {
        get { d.string(forKey: "genreMode") == "each" }
        set { d.set(newValue ? "each" : "same", forKey: "genreMode"); changed() }
    }
    static var defaultGenre: String {
        get { d.string(forKey: "defaultGenre") ?? "Dance" }
        set { d.set(newValue, forKey: "defaultGenre"); changed() }
    }
    /// The genre picked in the drop zone (same-genre mode).
    static var batchGenre: String {
        get { d.string(forKey: "batchGenre") ?? defaultGenre }
        set { d.set(newValue, forKey: "batchGenre"); changed() }
    }
    static var useFileGenre: Bool {
        get { d.object(forKey: "useFileGenre") as? Bool ?? true }
        set { d.set(newValue, forKey: "useFileGenre"); changed() }
    }
    static var tidyCaps: Bool {
        get { d.object(forKey: "tidyCaps") as? Bool ?? true }
        set { d.set(newValue, forKey: "tidyCaps"); changed() }
    }
    static var onlineArtwork: Bool {
        get { d.object(forKey: "onlineArtwork") as? Bool ?? true }
        set { d.set(newValue, forKey: "onlineArtwork"); changed() }
    }
    static var genres: [String] {
        get {
            let g = d.stringArray(forKey: "genres") ?? starterGenres
            return g.isEmpty ? starterGenres : g
        }
        set { d.set(newValue, forKey: "genres"); changed() }
    }

    // MARK: watch folder

    /// Watching is on whenever the app is open (ruled).
    static var watchEnabled: Bool {
        get { d.object(forKey: "watchEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "watchEnabled"); changed() }
    }
    static var watchFolder: URL {
        get { d.string(forKey: "watchFolder").map { URL(fileURLWithPath: $0) }
              ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
        set { d.set(newValue.path, forKey: "watchFolder"); changed() }
    }
    static var watchSubfolders: Bool {
        get { d.object(forKey: "watchSubfolders") as? Bool ?? true }
        set { d.set(newValue, forKey: "watchSubfolders"); changed() }
    }
    /// After a watched download is in Music: "leave", "bin" or "folder" (ruled: folder, user-selected).
    static var afterImport: String {
        get { d.string(forKey: "afterImport") ?? "folder" }
        set { d.set(newValue, forKey: "afterImport"); changed() }
    }
    /// The backup folder imported downloads are moved into; nil until chosen.
    static var backupFolder: URL? {
        get { d.string(forKey: "backupFolder").map { URL(fileURLWithPath: $0) } }
        set { d.set(newValue?.path, forKey: "backupFolder"); changed() }
    }

    /// The genre list plus any extra names (e.g. a file's own genre not in the list).
    static func genreMenu(including extra: [String] = []) -> [String] {
        var list = genres
        for e in extra where !e.isEmpty && !list.contains(e) { list.append(e) }
        return list
    }

    /// One-off: copy the settings the old app saved, so the renamed app keeps them.
    static func migrateFromBeatportTag() {
        guard d.object(forKey: "migratedFromBeatportTag") == nil else { return }
        d.set(true, forKey: "migratedFromBeatportTag")
        guard let old = UserDefaults(suiteName: "com.alexisarmstrong.beatporttag")?
                .persistentDomain(forName: "com.alexisarmstrong.beatporttag") else { return }
        for (key, value) in old where d.object(forKey: key) == nil
            && !key.hasPrefix("NS") && !key.hasPrefix("Apple") {
            d.set(value, forKey: key)
        }
    }
}

// MARK: - settings window (⌘, or the gear)

final class SettingsWindowController: NSWindowController, NSTokenFieldDelegate {
    private let same = NSButton(radioButtonWithTitle: "Same genre for every track in a batch", target: nil, action: nil)
    private let each = NSButton(radioButtonWithTitle: "Choose a genre for each track", target: nil, action: nil)
    private let defaultPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fileGenre = NSButton(checkboxWithTitle: "Start from the file’s own genre when it has one", target: nil, action: nil)
    private let tokens = NSTokenField()
    private let caps = NSButton(checkboxWithTitle: "Tidy titles and albums in ALL CAPS or lowercase", target: nil, action: nil)
    private let online = NSButton(checkboxWithTitle: "Look up missing covers online", target: nil, action: nil)
    private let watch = NSButton(checkboxWithTitle: "Watch a folder for new music downloads", target: nil, action: nil)
    private let folderLabel = NSTextField(labelWithString: "")
    private let subfolders = NSButton(checkboxWithTitle: "Include subfolders", target: nil, action: nil)
    private let leave = NSButton(radioButtonWithTitle: "Leave the download where it is", target: nil, action: nil)
    private let bin = NSButton(radioButtonWithTitle: "Move it to the Bin", target: nil, action: nil)
    private let move = NSButton(radioButtonWithTitle: "Move it to my backup folder:", target: nil, action: nil)
    private let backupLabel = NSTextField(labelWithString: "")

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Track Livery Settings"
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        self.init(window: w)
        build(in: w.contentView!)
        refresh()
        w.center()
    }

    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: 11.5)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func heading(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        l.font = .systemFont(ofSize: 13)
        return l
    }

    private func build(in v: NSView) {
        let H = v.bounds.height
        func place(_ view: NSView, x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat) {
            view.frame = NSRect(x: x, y: H - top - h, width: w, height: h)
            v.addSubview(view)
        }
        let lx: CGFloat = 20, lw: CGFloat = 130, cx: CGFloat = 166, cw: CGFloat = 370

        place(heading("Genre"), x: lx, top: 24, w: lw, h: 18)
        for b in [same, each] { b.target = self; b.action = #selector(modeChanged) }
        place(same, x: cx, top: 22, w: cw, h: 20)
        place(note("Pick it in the drop zone before you drop; files start at once."), x: cx + 20, top: 42, w: cw - 20, h: 16)
        place(each, x: cx, top: 64, w: cw, h: 20)
        place(note("The files wait in the track list, each with its own genre, until you press Import."), x: cx + 20, top: 84, w: cw - 20, h: 30)

        place(heading("Default genre"), x: lx, top: 124, w: lw, h: 18)
        defaultPopup.target = self
        defaultPopup.action = #selector(defaultChanged)
        place(defaultPopup, x: cx - 3, top: 119, w: 220, h: 26)

        place(heading("Starting point"), x: lx, top: 160, w: lw, h: 18)
        fileGenre.target = self
        fileGenre.action = #selector(fileGenreChanged)
        place(fileGenre, x: cx, top: 158, w: cw, h: 20)
        place(note("Downloads from music stores usually carry one (House, Nu Disco / Disco…). Otherwise the default genre is used."), x: cx + 20, top: 178, w: cw - 20, h: 30)

        place(heading("Genre list"), x: lx, top: 218, w: lw, h: 18)
        tokens.delegate = self
        tokens.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        tokens.font = .systemFont(ofSize: 12)
        tokens.target = self
        tokens.action = #selector(tokensChanged)
        place(tokens, x: cx, top: 216, w: cw, h: 96)
        place(note("Type a genre and a comma to add it; select one and press Delete to remove it."), x: cx, top: 316, w: cw, h: 16)

        place(heading("Capitals"), x: lx, top: 352, w: lw, h: 18)
        caps.target = self
        caps.action = #selector(capsChanged)
        place(caps, x: cx, top: 350, w: cw, h: 20)
        place(note("Title Case: each word capitalised except small words (and, of, the…). Mixed-case tags and artist names are left as they are."), x: cx + 20, top: 370, w: cw - 20, h: 30)

        place(heading("Covers"), x: lx, top: 412, w: lw, h: 18)
        online.target = self
        online.action = #selector(onlineChanged)
        place(online, x: cx, top: 410, w: cw, h: 20)
        place(note("Only when a download has no cover of its own. Sends the artist and title (never the music) to Apple’s iTunes Search and to MusicBrainz."), x: cx + 20, top: 430, w: cw - 20, h: 30)

        let sep = NSBox(); sep.boxType = .separator
        place(sep, x: 20, top: 472, w: 520, h: 1)
        place(heading("Watch folder"), x: lx, top: 488, w: lw, h: 18)
        watch.target = self; watch.action = #selector(watchChanged)
        place(watch, x: cx, top: 486, w: cw, h: 20)
        place(note("New downloads are listed and a notification asks whether to import them."), x: cx + 20, top: 506, w: cw - 20, h: 16)
        folderLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        place(folderLabel, x: cx + 20, top: 530, w: cw - 120, h: 18)
        let change = NSButton(title: "Change…", target: self, action: #selector(chooseWatchFolder))
        change.controlSize = .small
        place(change, x: cx + cw - 92, top: 526, w: 90, h: 24)
        subfolders.target = self; subfolders.action = #selector(subfoldersChanged)
        place(subfolders, x: cx + 20, top: 554, w: cw - 20, h: 20)

        place(heading("Afterwards"), x: lx, top: 588, w: lw, h: 18)
        for b in [leave, bin, move] { b.target = self; b.action = #selector(afterChanged) }
        place(leave, x: cx, top: 586, w: cw, h: 20)
        place(bin, x: cx, top: 608, w: cw, h: 20)
        place(move, x: cx, top: 630, w: 210, h: 20)
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseBackup))
        choose.controlSize = .small
        place(choose, x: cx + cw - 92, top: 628, w: 90, h: 24)
        backupLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        backupLabel.lineBreakMode = .byTruncatingMiddle
        place(backupLabel, x: cx + 20, top: 654, w: cw - 20, h: 18)
        place(note("Only after Music has the track. The spare converted copy goes to the Bin once Music has its own."), x: cx + 20, top: 672, w: cw - 20, h: 16)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(nil) // don't open with every genre selected
    }

    func refresh() {
        same.state = Prefs.perTrack ? .off : .on
        each.state = Prefs.perTrack ? .on : .off
        defaultPopup.removeAllItems()
        defaultPopup.addItems(withTitles: Prefs.genreMenu(including: [Prefs.defaultGenre]))
        defaultPopup.selectItem(withTitle: Prefs.defaultGenre)
        fileGenre.state = Prefs.useFileGenre ? .on : .off
        tokens.objectValue = Prefs.genres
        caps.state = Prefs.tidyCaps ? .on : .off
        online.state = Prefs.onlineArtwork ? .on : .off
        watch.state = Prefs.watchEnabled ? .on : .off
        folderLabel.stringValue = (Prefs.watchFolder.path as NSString).abbreviatingWithTildeInPath
        subfolders.state = Prefs.watchSubfolders ? .on : .off
        leave.state = Prefs.afterImport == "leave" ? .on : .off
        bin.state = Prefs.afterImport == "bin" ? .on : .off
        move.state = Prefs.afterImport == "folder" ? .on : .off
        backupLabel.stringValue = Prefs.backupFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Not chosen yet: downloads stay where they are"
        backupLabel.textColor = Prefs.backupFolder == nil ? .systemOrange : .labelColor
    }

    @objc private func watchChanged() { Prefs.watchEnabled = watch.state == .on }
    @objc private func subfoldersChanged() { Prefs.watchSubfolders = subfolders.state == .on }
    @objc private func afterChanged(_ sender: NSButton) {
        Prefs.afterImport = sender === leave ? "leave" : sender === bin ? "bin" : "folder"
        refresh()
    }

    private func pickFolder(_ message: String, start: URL?, done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.directoryURL = start
        guard let w = window else { return }
        panel.beginSheetModal(for: w) { r in if r == .OK, let u = panel.url { done(u) } }
    }

    @objc private func chooseWatchFolder() {
        pickFolder("Choose the folder to watch for new music downloads", start: Prefs.watchFolder) { [weak self] u in
            Prefs.watchFolder = u; self?.refresh()
        }
    }

    @objc private func chooseBackup() {
        pickFolder("Choose the folder imported downloads are moved into", start: Prefs.backupFolder ?? Prefs.watchFolder) { [weak self] u in
            Prefs.backupFolder = u; Prefs.afterImport = "folder"; self?.refresh()
        }
    }

    @objc private func modeChanged(_ sender: NSButton) { Prefs.perTrack = sender === each; refresh() }
    @objc private func defaultChanged() { if let t = defaultPopup.titleOfSelectedItem { Prefs.defaultGenre = t } }
    @objc private func fileGenreChanged() { Prefs.useFileGenre = fileGenre.state == .on }
    @objc private func capsChanged() { Prefs.tidyCaps = caps.state == .on }
    @objc private func onlineChanged() { Prefs.onlineArtwork = online.state == .on }
    @objc private func tokensChanged() { saveTokens() }
    func controlTextDidEndEditing(_ obj: Notification) { saveTokens() }

    private func saveTokens() {
        let list = (tokens.objectValue as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        for g in list where !unique.contains(g) { unique.append(g) }
        if !unique.isEmpty, unique != Prefs.genres { Prefs.genres = unique; refresh() }
    }
}
