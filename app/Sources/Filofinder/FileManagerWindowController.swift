import AppKit

/// One Filofinder window: captools' File Manager layout (UI-SPEC §2).
/// Owns all state; views read it and call back into the action methods.
final class FileManagerWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    static let zoomRange: ClosedRange<CGFloat> = 0.5...2.5

    // MARK: State

    private(set) var tabs: [Tab] = []
    /// The tab-bar tab (left pane, or the only pane).
    private(set) var leftTab: Tab
    /// The right pane's tab in split view.
    private(set) var rightTab: Tab?
    private(set) var splitMode = false
    private(set) var focused: Side = .left
    private(set) var previewName: String?

    /// The tab every action applies to: the focused pane's.
    var activeTab: Tab { tab(for: splitMode ? focused : .left) }

    func tab(for side: Side) -> Tab {
        side == .right ? (rightTab ?? leftTab) : leftTab
    }
    var multiSelect = false

    var viewMode: ViewMode {
        get { ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .grid }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "viewMode") }
    }
    var zoom: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1.0) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "zoom") }
    }
    static let textSizeRange: ClosedRange<CGFloat> = 8...20
    /// Size of file/folder names, separate from icon zoom (default 10 pt, captools).
    var textSize: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "textSize") as? Double ?? 10) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "textSize") }
    }
    var showTree: Bool {
        get { UserDefaults.standard.object(forKey: "showTree") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showTree") }
    }
    var showPreview: Bool {
        get { UserDefaults.standard.bool(forKey: "showPreview") }
        set { UserDefaults.standard.set(newValue, forKey: "showPreview") }
    }
    private var showHidden = false
    private var sortField: SortField = .name
    private var sortDescending = false

    // MARK: Views

    private var toolbar: ToolbarView!
    private var tabBar: TabBarView!
    private var breadcrumbs: BreadcrumbBar!
    private var tree: TreeSidebar!
    private var leftPane: PaneView!
    private var rightPane: PaneView!
    private let panes = TintSplitView()
    /// The focused pane's file view.
    private var panel: FilePanel { (splitMode && focused == .right ? rightPane : leftPane).panel }
    private var preview: PreviewPaneView!
    private(set) lazy var ops = FileOps(fm: self)
    /// Live refresh for the folder shown in each pane.
    private var appearanceObservation: NSKeyValueObservation?
    private lazy var leftWatcher = FolderWatcher { [weak self] in self?.externalChange(.left) }
    private lazy var rightWatcher = FolderWatcher { [weak self] in self?.externalChange(.right) }
    private(set) lazy var quickLook = QuickLookController(fm: self)
    private var activity: String?
    private let split = TintSplitView()
    private let frameMonitor = FrameMonitor()
    private var frameText = ""

    init(path: String?) {
        let first = Tab(path: path ?? Tab.home)
        leftTab = first
        tabs = Self.loadPinnedTabs() + [first]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Experimental: a system toolbar (even empty) makes macOS draw the larger traffic lights; our own bar is a plain view.
        window.toolbar = NSToolbar(identifier: "FiloBrootMain")
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed // captools has its own tab bar
        window.minSize = NSSize(width: 900, height: 480)
        window.setFrameAutosaveName("FilofinderMain")
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        window.delegate = self
        buildLayout()
        registerObservers()
        load(leftTab)
        refreshAll()
    }

    /// App-wide notifications; registered once, because buildLayout() runs
    /// again whenever the whole-UI zoom changes.
    private func registerObservers() {
        // Tags changed (context menu): refresh dots everywhere.
        NotificationCenter.default.addObserver(forName: Tags.changed, object: nil, queue: .main) { [weak self] _ in
            Tags.clearCache()
            guard let self else { return }
            self.leftPane.panel.reloadVisible()
            if self.splitMode { self.rightPane.panel.reloadVisible() }
            if self.activeTab.isVirtual { self.refresh(nil) }
        }
        NotificationCenter.default.addObserver(forName: UIZoom.changed, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildForZoom()
        }
    }

    /// ⌘+ / ⌘− / ⌘0: rebuild every view at the new scale. All state (tabs,
    /// listings, selection, history) lives in this controller, so nothing
    /// is lost; only scroll positions reset.
    private func rebuildForZoom() {
        guard let content = window?.contentView else { return }
        let wasMonitoring = !frameText.isEmpty
        frameMonitor.stop()
        preview?.stop()
        for s in [split, panes] {
            for v in s.arrangedSubviews { s.removeArrangedSubview(v); v.removeFromSuperview() }
        }
        content.subviews.forEach { $0.removeFromSuperview() }
        buildLayout()
        refreshAll()
        leftPane.panel.reload()
        if splitMode { rightPane.panel.reload() }
        if wasMonitoring { frameMonitor.start(on: panel) }
        window?.makeFirstResponder(panel.focusTarget)
        updateFocusCue()
        UI.hud("Zoom \(UIZoom.percent)", in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        toolbar = ToolbarView(fm: self)
        tabBar = TabBarView(fm: self)
        breadcrumbs = BreadcrumbBar(fm: self)
        tree = TreeSidebar(fm: self)
        leftPane = PaneView(fm: self, side: .left)
        rightPane = PaneView(fm: self, side: .right)
        preview = PreviewPaneView(fm: self)
        panes.isVertical = true
        panes.dividerStyle = .thick
        panes.delegate = self
        panes.addArrangedSubview(leftPane)
        panes.addArrangedSubview(rightPane)

        let top = UI.bar(material: .titlebar, height: 40)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        top.addSubview(toolbar)
        pin(toolbar, to: top)

        split.isVertical = true
        split.dividerStyle = .thin
        #if DEBUG
        if ProcessInfo.processInfo.environment["FILOFINDER_PAINT_DIVIDERS"] != nil {
            split.tint = .systemRed
            panes.tint = .systemBlue
        }
        #endif
        split.delegate = self
        split.addArrangedSubview(tree)
        split.addArrangedSubview(panes)
        split.addArrangedSubview(preview)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(200), forSubviewAt: 1)
        split.setHoldingPriority(.init(250), forSubviewAt: 2)

        let body = NSView()
        split.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(split)
        pin(split, to: body)

        let line = NSBox()
        line.boxType = .separator
        tabBar.heightAnchor.constraint(equalToConstant: Z(34)).isActive = true
        breadcrumbs.heightAnchor.constraint(equalToConstant: Z(38)).isActive = true

        let column = NSStackView(views: [top, tabBar, breadcrumbs, line, body])
        column.orientation = .vertical
        column.spacing = 0
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        for v in column.arrangedSubviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        body.setContentHuggingPriority(.init(1), for: .vertical)
        content.addSubview(column)
        pin(column, to: content)

        // Light/Dark switch: colours baked into layers and labels must be
        // rebuilt right away, not on the next relaunch.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.appearanceChanged() }
        }

        frameMonitor.onReport = { [weak self] r in
            self?.frameText = String(format: "· %.0f fps @ %.0f Hz · dropped %d", r.fps, r.refreshHz, r.dropped)
            self?.updateStatus()
        }

        // The old AppKit autosave stored a 0-width tree after split view hid it.
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames FilofinderSplit")
    }

    // Side panel widths are remembered by us, only while visible, so hiding
    // a panel (split view) can never save it as 0 px wide.
    private var treeWidth: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "treeWidth") as? Double ?? 220) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "treeWidth") }
    }
    private var previewWidth: CGFloat {
        get { CGFloat(UserDefaults.standard.object(forKey: "previewWidth") as? Double ?? 400) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "previewWidth") }
    }
    private var restoringWidths = false

    /// Gives visible side panels their remembered width (captools defaults:
    /// tree 220, preview 400) whenever they appear.
    private func restoreSideWidths() {
        restoringWidths = true
        defer { restoringWidths = false }
        split.layoutSubtreeIfNeeded()
        if !tree.isHidden, tree.frame.width < 80 || abs(tree.frame.width - treeWidth) > 1 {
            split.setPosition(min(max(treeWidth, 80), 540), ofDividerAt: 0)
        }
        if !preview.isHidden, preview.frame.width < 200 || abs(preview.frame.width - previewWidth) > 1 {
            split.setPosition(split.bounds.width - min(max(previewWidth, 200), 700) - split.dividerThickness, ofDividerAt: 1)
        }
    }

    private func pin(_ v: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor), v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            v.topAnchor.constraint(equalTo: parent.topAnchor), v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    /// No divider next to a hidden panel. (AppKit would otherwise keep
    /// drawing it at the hidden panel's old edge — the "ghost line" left
    /// behind after closing the folder tree.)
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        let views = splitView.arrangedSubviews
        guard dividerIndex + 1 < views.count else { return true }
        return views[dividerIndex].isHidden || views[dividerIndex + 1].isHidden
    }

    // Tree 80–540, preview 200–700; split panes at least 20% each (captools limits).
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        if splitView === panes { return splitView.bounds.width * 0.2 }
        return index == 0 ? 80 : max(proposed, splitView.bounds.width - 700)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        if splitView === panes { return splitView.bounds.width * 0.8 }
        return index == 0 ? 540 : min(proposed, splitView.bounds.width - 200)
    }

    // MARK: Refresh

    private func appearanceChanged() {
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            refreshAll()
            leftPane.panel.reloadVisible()
            if splitMode { rightPane.panel.reloadVisible() }
            window?.contentView?.needsDisplay = true
            window?.contentView?.subviews.forEach { $0.needsDisplay = true }
        }
    }

    /// Something outside Filofinder changed a visible folder: re-list it,
    /// keeping the selection (skipped while our own job is running — it
    /// refreshes when done).
    private func externalChange(_ side: Side) {
        guard !ops.busy, side == .left || splitMode else { return }
        load(tab(for: side), keepSelection: true)
    }

    private func updateWatchers() {
        leftWatcher.watch(leftTab.isVirtual || leftTab.accessDenied ? nil : leftTab.path)
        rightWatcher.watch(splitMode && !(rightTab?.isVirtual ?? true) ? rightTab?.path : nil)
    }

    func refreshAll() {
        updateWatchers()
        // captools: split view hides the tab bar, breadcrumbs, tree and
        // preview pane; each pane gets its own header and status bar.
        tabBar.isHidden = splitMode
        breadcrumbs.isHidden = splitMode
        tree.isHidden = splitMode || !showTree
        preview.isHidden = splitMode || !showPreview
        rightPane.isHidden = !splitMode
        split.adjustSubviews()
        panes.adjustSubviews()
        restoreSideWidths()
        toolbar.update()
        if !splitMode {
            tabBar.update()
            breadcrumbs.update()
            breadcrumbs.search.show(leftTab.query)
        }
        if showTree && !splitMode { tree.update() }
        leftPane.update()
        if splitMode { rightPane.update() }
        if showPreview && !splitMode { preview.update() }
        updateStatus()
        window?.title = activeTab.name
        window?.representedURL = URL(fileURLWithPath: activeTab.path)
        updateFocusCue()
    }

    private func updateStatus() {
        let hiddenNote = showHidden ? "Hidden files shown · " : ""
        leftPane.footer.update(tab: leftTab, timing: (focused == .left ? activity : nil) ?? (hiddenNote + leftTab.timing + frameText), tone: .left)
        if splitMode, let r = rightTab {
            rightPane.footer.update(tab: r, timing: (focused == .right ? activity : nil) ?? r.timing, tone: .right)
        }
        breadcrumbs.search.setMatchCount(leftTab.listing.map { Int($0.count()) })
    }

    /// Status-bar timing text for a broot result.
    private static func treeTiming(_ listing: ListingHandle) -> String {
        let s = listing.stats()
        var t = String(format: "broot %.0f ms · %d rows", Double(s.listMicros) / 1000, Int(listing.count()))
        let more = listing.treeUnlisted()
        if more > 0 { t += " · \(more) more not shown" }
        return t
    }

    func debugTreeClick(row: Int) { tree.debugClick(row: row) }

    #if DEBUG
    func debugDumpLayout() -> String {
        func f(_ v: NSView) -> String { "\(type(of: v)) hidden=\(v.isHidden) frame=\(v.frame)" }
        var out = "split: \(split.frame) divider=\(split.dividerThickness)\n"
        for v in split.subviews { out += "  split.sub \(f(v))\n" }
        for v in panes.subviews { out += "  panes.sub \(f(v))\n" }
        return out
    }
    #endif

    /// A pane's frame in window coordinates (the toolbar aligns to it).
    func paneFrameInWindow(_ side: Side) -> NSRect? {
        let pane: NSView = side == .right ? rightPane : leftPane
        guard !pane.isHidden, pane.window != nil else { return nil }
        return pane.convert(pane.bounds, to: nil)
    }

    /// Divider drags and window resizes move the panes; keep the cluster aligned.
    func splitViewDidResizeSubviews(_ notification: Notification) {
        toolbar?.positionCluster(animated: false)
        // Remember widths the user sets by dragging (visible panels only).
        guard (notification.object as? NSSplitView) === split, !restoringWidths else { return }
        if let tree, !tree.isHidden, tree.frame.width >= 80 { treeWidth = tree.frame.width }
        if let preview, !preview.isHidden, preview.frame.width >= 200 { previewWidth = preview.frame.width }
    }

    /// Makes `side` the target of toolbar actions (click or hover, captools).
    func focus(_ side: Side) {
        let side = splitMode ? side : .left
        guard side != focused else { return }
        focused = side
        toolbar.update()
        leftPane.update()
        if splitMode { rightPane.update() }
        quickLook.selectionChanged()
        window?.title = activeTab.name
    }

    var focusTarget: NSView { panel.focusTarget }

    /// Tab / ⇧Tab (single pane): keyboard focus moves between the file list
    /// and the Explorer, so typing filters through broot or locates in the tree.
    func toggleExplorerFocus(fromExplorer: Bool) {
        guard let window, !splitMode else { return }
        if fromExplorer {
            window.makeFirstResponder(panel.focusTarget)
        } else if showTree && !tree.isHidden {
            tree.focusOutline()
        }
        updateFocusCue()
    }

    /// Called from the first-responder hooks of the list, grid and Explorer.
    /// Deferred, because resignFirstResponder runs before the next view is set.
    func focusCueMayHaveChanged() {
        DispatchQueue.main.async { [weak self] in self?.updateFocusCue() }
    }

    /// Coloured ring (the split-pane ring, left tone) around the file list
    /// while it has focus; accent border around the Explorer while it does.
    func updateFocusCue() {
        guard !splitMode else { return }
        if tree.isHidden, tree.hasKeyboardFocus { window?.makeFirstResponder(panel.focusTarget) }
        let explorer = !tree.isHidden && tree.hasKeyboardFocus
        leftPane.setSingleCue(!explorer)
        tree.setFocusCue(explorer)
    }

    func selectionDidChange() {
        if showPreview { syncPreviewToSelection() }
        quickLook.selectionChanged()
        toolbar.update()
        updateStatus()
    }

    func pageChanged(current: Int, total: Int) {
        toolbar.updatePage(current: current, total: total)
    }

    // MARK: Loading

    /// Lists the tab's folder off the main thread. A newer request bumps
    /// `generation`, so a slow older listing never overwrites a newer one.
    /// Lists `path` (default: the tab's folder) off the main thread. The
    /// current folder stays on screen until the new one is ready (Finder
    /// behaviour); `onSuccess` runs only if the new folder opened.
    private func load(_ tab: Tab, path target: String? = nil, keepSelection: Bool = false, scrollToSelection: Bool = false,
                      onSuccess: (() -> Void)? = nil) {
        let path = target ?? tab.path
        tab.generation += 1
        let gen = tab.generation
        let started = CACurrentMediaTime()
        if target != nil { cancelTreeSearch(tab) }
        // Only tag tabs use the old substring filter; folders filter through broot.
        let virtual = Tags.tag(fromPath: path) != nil
        let hidden = showHidden, field = sortField, desc = sortDescending, query = target == nil && virtual ? tab.query : ""
        tab.loading = true
        // A slow open is almost always macOS checking privacy permission
        // (Desktop, Documents, Downloads, drives). Say so instead of looking frozen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, tab.loading, tab.generation == gen, self.pane(showing: tab) != nil else { return }
            let name = (path as NSString).lastPathComponent
            self.setActivity("Opening “\(name)”… if macOS is asking for permission, click Allow")
        }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let result = Result { () -> ListingHandle in
                // Tag tabs list Spotlight results instead of a folder.
                let l = try Tags.tag(fromPath: path).map { listPaths(paths: Tags.search($0), title: path, showHidden: hidden) }
                    ?? listDir(path: path, showHidden: hidden, backend: .bulk)
                if field != .name || desc || !query.isEmpty { l.setView(field: field, descending: desc, query: query) }
                return l
            }
            DispatchQueue.main.async {
                guard let self, gen == tab.generation else { return }
                tab.loading = false
                if self.activity?.hasPrefix("Opening “") == true { self.setActivity(nil) }
                switch result {
                case .success(let listing):
                    Tags.clearCache()
                    tab.accessDenied = false
                    if !keepSelection { tab.selection = [] }
                    if target != nil { tab.query = "" }
                    onSuccess?()
                    tab.folderListing = listing
                    tab.path = listing.path()
                    let s = listing.stats()
                    tab.timing = String(format: "list %.0f ms · sort %.0f ms · %.0f ms total",
                                         Double(s.listMicros) / 1000, Double(s.sortMicros) / 1000,
                                         (CACurrentMediaTime() - started) * 1000)
                    if !tab.query.isEmpty && !tab.isVirtual {
                        // A broot filter is active (refresh, hidden files
                        // toggled, folder changed on disk): keep its rows on
                        // screen and search again.
                        if tab.listing == nil { tab.listing = listing; tab.resetRows() }
                        self.runTreeSearch(tab, keepSelection: true)
                    } else {
                        tab.listing = listing
                        tab.resetRows()
                    }
                    if let pane = self.pane(showing: tab) {
                        if !keepSelection { pane.panel.scrollToTop() }
                        self.refreshAll()
                        if scrollToSelection { pane.panel.scrollToSelection() }
                        self.refocusPanel(pane)
                    }
                case .failure(let error):
                    let denied = "\(error)".contains("not permitted") || "\(error)".contains("Permission denied")
                    if denied {
                        // Open the folder anyway and explain in place (Finder
                        // does the same), instead of silently staying put.
                        onSuccess?()
                        tab.path = path
                        tab.listing = nil
                        tab.folderListing = nil
                        tab.rows = []
                        tab.selection = []
                        tab.accessDenied = true
                        tab.timing = ""
                    } else {
                        UI.hud("⚠︎ \(error)", in: self.window)
                        NSSound.beep()
                    }
                    self.refreshAll()
                }
            }
        }
    }

    /// The pane currently displaying `tab`, if any.
    private func pane(showing tab: Tab) -> PaneView? {
        if tab === leftTab { return leftPane }
        if splitMode, tab === rightTab { return rightPane }
        return nil
    }

    /// Opens `path` in the active tab; `select` names an item in it to
    /// select and scroll to (Go to Folder with a file path, Reveal in Finder).
    func navigate(to path: String, select: String? = nil) {
        let tab = activeTab
        let target = (path as NSString).standardizingPath
        guard target != tab.path || !tab.query.isEmpty else {
            if let select { selectAndShow(select, in: tab) }
            return
        }
        let from = tab.path
        go(tab, to: target, scrollToSelection: select != nil) {
            if target != from {
                tab.back.append(from)
                tab.forward.removeAll()
            }
            if let select { tab.selection = [select] }
        }
    }

    private func go(_ tab: Tab, to path: String, scrollToSelection: Bool = false, onSuccess: @escaping () -> Void) {
        load(tab, path: path, scrollToSelection: scrollToSelection) { [weak self] in
            self?.previewName = nil
            onSuccess()
        }
    }

    private func selectAndShow(_ name: String, in tab: Tab) {
        tab.selection = [name]
        guard let pane = pane(showing: tab) else { return }
        pane.panel.applySelection()
        pane.panel.scrollToSelection()
        selectionDidChange()
    }

    /// After a panel switches between grid and list (broot results are
    /// always a list), keep keyboard focus on the visible view.
    private func refocusPanel(_ pane: PaneView) {
        guard let window, pane.side == focused || !splitMode else { return }
        let fr = window.firstResponder
        guard fr === pane.panel.grid || fr === pane.panel.list || fr === window || fr == nil else { return }
        if fr !== pane.panel.focusTarget { window.makeFirstResponder(pane.panel.focusTarget) }
    }

    // MARK: Tabs

    func switchTo(_ tab: Tab) {
        guard tab !== leftTab else { return }
        if tab === rightTab { rightTab = leftTab } // never show one tab twice
        leftTab = tab
        focused = .left
        previewName = nil
        if tab.listing == nil { load(tab) }
        leftPane.panel.scrollToTop()
        refreshAll()
    }

    /// Split-panel tab picker: show `tab` in `side` (swaps if it's on the other side).
    func assign(_ tab: Tab, to side: Side) {
        focused = side
        if side == .left {
            if tab === rightTab { rightTab = leftTab }
            leftTab = tab
        } else {
            if tab === leftTab { leftTab = rightTab ?? leftTab }
            rightTab = tab
        }
        if tab.listing == nil { load(tab) }
        refreshAll()
    }

    /// "Show in Finder" from other apps (when Filofinder is the default file
    /// browser): open the enclosing folder in a new tab with the items selected.
    func reveal(_ paths: [String]) {
        guard let first = paths.first else { return }
        let parent = (first as NSString).deletingLastPathComponent
        let tab = Tab(path: parent.isEmpty ? "/" : parent)
        tab.selection = Set(paths.filter { ($0 as NSString).deletingLastPathComponent == parent }
            .map { ($0 as NSString).lastPathComponent })
        tabs.append(tab)
        if tab === rightTab { rightTab = leftTab }
        leftTab = tab
        focused = .left
        previewName = nil
        load(tab, keepSelection: true, scrollToSelection: true)
        refreshAll()
    }

    /// Default-file-viewer entry point for folders (Finder "open"): a new
    /// tab at that folder.
    func openFolderInNewTab(_ path: String) {
        let tab = Tab(path: (path as NSString).standardizingPath)
        tabs.append(tab)
        if tab === rightTab { rightTab = leftTab }
        leftTab = tab
        focused = .left
        previewName = nil
        load(tab)
        refreshAll()
    }

    /// ⌥⌘C: the selected items' paths, or the current folder's when nothing is selected.
    @objc func copyPathAction(_ sender: Any?) {
        guard !activeTab.isVirtual || !selectedPaths().isEmpty else { NSSound.beep(); return }
        let paths = selectedPaths().isEmpty ? [activeTab.path] : selectedPaths()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        UI.hud(paths.count == 1 ? "Path copied" : "\(paths.count) paths copied", in: window)
    }

    @objc func newTab(_ sender: Any?) {
        let tab = Tab()
        tabs.append(tab)
        switchTo(tab)
    }

    // MARK: Pinned tabs

    private static let pinnedKey = "pinnedTabs"

    private static func loadPinnedTabs() -> [Tab] {
        (UserDefaults.standard.stringArray(forKey: pinnedKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { let t = Tab(path: $0); t.pinnedPath = $0; return t }
    }

    private func savePinnedTabs() {
        UserDefaults.standard.set(tabs.compactMap(\.pinnedPath), forKey: Self.pinnedKey)
    }

    func canPin(_ tab: Tab) -> Bool { !tab.isVirtual }

    /// Pin at the tab's current folder (pinned tabs sit first), or unpin.
    func togglePin(_ tab: Tab) {
        tab.pinnedPath = tab.isPinned ? nil : tab.path
        tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        savePinnedTabs()
        refreshAll()
    }

    func close(_ tab: Tab) {
        guard !tab.isPinned, tabs.count > 1, let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: i)
        if tab === rightTab { rightTab = nil; splitMode = false; focused = .left }
        if tab === leftTab {
            leftTab = tabs[min(i, tabs.count - 1)]
            if leftTab === rightTab { rightTab = nil; splitMode = false; focused = .left }
            previewName = nil
        }
        if leftTab.listing == nil { load(leftTab) }
        refreshAll()
    }

    func duplicate(_ tab: Tab) {
        let copy = tab.duplicate()
        tabs.insert(copy, at: (tabs.firstIndex(where: { $0 === tab }) ?? tabs.count - 1) + 1)
        switchTo(copy)
    }

    func closeOthers(than tab: Tab) {
        tabs = tabs.filter { $0.isPinned || $0 === tab }
        rightTab = nil
        splitMode = false
        focused = .left
        if tab !== leftTab { switchTo(tab) }
        refreshAll()
    }

    func closeTabsRight(of tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        let removed = tabs[(i + 1)...].filter { !$0.isPinned }
        tabs.removeAll { t in removed.contains { $0 === t } }
        if let r = rightTab, removed.contains(where: { $0 === r }) { rightTab = nil; splitMode = false; focused = .left }
        if removed.contains(where: { $0 === leftTab }) { switchTo(tab) }
        refreshAll()
    }

    // MARK: Toolbar actions

    @objc func toggleTree(_ sender: Any?) {
        showTree.toggle()
        refreshAll()
    }

    @objc func openDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: activeTab.path)
        panel.prompt = "Go"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.navigate(to: url.path)
        }
    }

    @objc func openZip(_ sender: Any?) { notYet("ZIP browsing arrives in v0.2") }
    /// ⌘M. Opens a second pane with another open tab, or a duplicate of the
    /// current tab when it's the only one (captools behaviour).
    @objc func toggleSplit(_ sender: Any?) {
        if splitMode {
            splitMode = false
            focused = .left
        } else {
            let other: Tab
            if let r = rightTab, tabs.contains(where: { $0 === r }), r !== leftTab {
                other = r
            } else if let t = tabs.first(where: { $0 !== leftTab }) {
                other = t
            } else {
                other = leftTab.duplicate()
                tabs.append(other)
            }
            rightTab = other
            splitMode = true
            if other.listing == nil { load(other) }
        }
        refreshAll()
        if splitMode {
            DispatchQueue.main.async { self.panes.setPosition(self.panes.bounds.width / 2, ofDividerAt: 0) }
        }
    }

    /// Close button in a split header: closing the left pane promotes the
    /// right one; closing the right pane leaves split view.
    func closePane(_ side: Side) {
        guard splitMode else { return }
        if side == .left, let r = rightTab { leftTab = r }
        splitMode = false
        focused = .left
        refreshAll()
    }
    var showsHidden: Bool { showHidden }

    /// The real macOS Trash. Listing it needs Full Disk Access; without it,
    /// Finder's Trash window opens instead.
    @objc func openTrash(_ sender: Any?) {
        // Always in-app. Without Full Disk Access the panel explains how to
        // allow it instead of throwing the user over to Finder.
        navigate(to: Tab.trashPath)
    }
    @objc func redoAction(_ sender: Any?) { notYet("Redo arrives in a later build") }
    @objc func createZip(_ sender: Any?) { notYet("Create ZIP arrives in v0.2") }

    // MARK: File operations (FileOps → Rust core)

    /// Full paths of the selected items, in display order.
    func selectedPaths() -> [String] {
        let tab = activeTab
        return panel.selectedIndexes().compactMap { tab.row($0).map { tab.fullPath($0.name) } }
    }

    private func requireSelection() -> [String]? {
        let paths = selectedPaths()
        if paths.isEmpty { NSSound.beep(); return nil }
        return paths
    }

    /// Tag results aren't a folder: nothing can be created or pasted there.
    private func requireRealFolder() -> Bool {
        guard activeTab.isVirtual else { return true }
        UI.hud("This is a tag view — open a folder to add items", in: window)
        return false
    }

    @objc func newFolder(_ sender: Any?) { if requireRealFolder() { ops.newFolder(in: activeTab.path) } }
    /// While a text field (the filter) is being edited, the Edit
    /// menu's ⌘C ⌘X ⌘V ⌘A ⌘Z act on its text, not on files.
    /// (Menu invocations only: toolbar buttons keep acting on files.)
    /// The field editor of whatever text field has focus: in this window, or in its sheet (Go to Folder), which is the key window while it is up.
    private var textEditor: NSTextView? { (window?.attachedSheet ?? window)?.firstResponder as? NSTextView }

    /// The Edit menu sends the standard copy:/cut:/paste: (nil target), so a focused text field's field editor handles them first, including in the Go to Folder sheet, whose responder chain never reaches this controller. Only when no text field takes them do they arrive here and act on files.
    @objc(copy:) func copyAction(_ sender: Any?) { copyItems(sender) }
    @objc(cut:) func cutAction(_ sender: Any?) { cutItems(sender) }
    @objc(paste:) func pasteAction(_ sender: Any?) { pasteItems(sender) }

    @objc func copyItems(_ sender: Any?) { if sender is NSMenuItem, let t = textEditor { t.copy(sender); return }; if let p = requireSelection() { ops.copy(p); panel.reloadVisible(); toolbar.update() } }
    @objc func cutItems(_ sender: Any?) { if sender is NSMenuItem, let t = textEditor { t.cut(sender); return }; if let p = requireSelection() { ops.cut(p); leftPane.panel.reloadVisible(); rightPane.panel.reloadVisible(); toolbar.update() } }
    @objc func pasteItems(_ sender: Any?) { if sender is NSMenuItem, let t = textEditor { t.paste(sender); return }; if requireRealFolder() { ops.paste(into: activeTab.path) } }
    @objc func undoAction(_ sender: Any?) { if sender is NSMenuItem, let t = textEditor { t.undoManager?.undo(); return }; ops.undo() }
    @objc func moveToBin(_ sender: Any?) {
        guard let p = requireSelection() else { return }
        if activeTab.isTrash { ops.deletePermanently(p) } else { ops.moveToTrash(p) }
    }
    @objc func deletePermanently(_ sender: Any?) { if let p = requireSelection() { ops.deletePermanently(p) } }
    @objc func duplicateItems(_ sender: Any?) { if let p = requireSelection() { ops.duplicate(p) } }
    @objc func renameItem(_ sender: Any?) {
        let paths = selectedPaths()
        guard paths.count == 1 else { NSSound.beep(); return }
        ops.rename(paths[0])
    }

    /// Paths currently cut (shown faded, like Windows Explorer).
    func isCut(_ path: String) -> Bool {
        ops.cutPaths.contains(path)
    }

    func setActivity(_ text: String?) {
        activity = text
        toolbar.update()
        updateStatus()
    }

    /// After any operation: re-list the folder and select what just landed.
    func operationFinished(select names: [String]) {
        if !names.isEmpty { activeTab.selection = Set(names) }
        load(activeTab, keepSelection: true)
        // The other pane may show the source or destination folder.
        if splitMode { load(tab(for: focused.other), keepSelection: true) }
        tree.refreshExpanded()
        toolbar.update()
    }

    private func notYet(_ message: String) {
        UI.hud(message, in: window)
    }

    @objc func toggleMultiSelect(_ sender: Any?) {
        multiSelect.toggle()
        refreshAll()
    }

    @objc func selectAllItems(_ sender: Any?) {
        if sender is NSMenuItem, let t = textEditor { t.selectAll(sender); return }
        let tab = activeTab
        tab.selection = Set((0..<tab.rows.count).compactMap { tab.row($0)?.name })
        panel.applySelection()
        selectionDidChange()
    }

    @objc func invertSelection(_ sender: Any?) {
        let tab = activeTab
        let all = Set((0..<tab.rows.count).compactMap { tab.row($0)?.name })
        tab.selection = all.subtracting(tab.selection)
        panel.applySelection()
        selectionDidChange()
    }

    @objc func setListView(_ sender: Any?) {
        viewMode = .list
        refreshAll()
    }

    @objc func setGridView(_ sender: Any?) {
        viewMode = .grid
        refreshAll()
    }

    @objc func zoomOut(_ sender: Any?) { zoomBy(-0.2) }
    @objc func zoomIn(_ sender: Any?) { zoomBy(0.2) }

    // Whole-UI zoom (⌘+ / ⌘− / ⌘0); every window rebuilds via UIZoom.changed.
    @objc func uiZoomIn(_ sender: Any?) { UIZoom.zoomIn() }
    @objc func uiZoomOut(_ sender: Any?) { UIZoom.zoomOut() }
    @objc func uiZoomReset(_ sender: Any?) { UIZoom.reset() }

    func zoomBy(_ delta: CGFloat) {
        let z = min(max(zoom + delta, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard abs(z - zoom) > 0.001 else { return }
        zoom = (z * 10).rounded() / 10
        leftPane.panel.reload()
        if splitMode { rightPane.panel.reload() }
        toolbar.update()
    }

    @objc func textSmaller(_ sender: Any?) { textSizeBy(-1) }
    @objc func textLarger(_ sender: Any?) { textSizeBy(1) }

    private func textSizeBy(_ delta: CGFloat) {
        let t = min(max(textSize + delta, Self.textSizeRange.lowerBound), Self.textSizeRange.upperBound)
        guard t != textSize else { NSSound.beep(); return }
        textSize = t
        leftPane.panel.reload()
        if splitMode { rightPane.panel.reload() }
        toolbar.update()
        UI.hud("Name text: \(Int(t)) pt", in: window)
    }

    @objc func pageUpAction(_ sender: Any?) { panel.page(-1) }
    @objc func pageDownAction(_ sender: Any?) { panel.page(1) }

    @objc func togglePreview(_ sender: Any?) {
        showPreview.toggle()
        if showPreview { syncPreviewToSelection() } else { previewName = nil; preview.stop() }
        refreshAll()
    }

    // MARK: Navigation actions

    @objc func goBack(_ sender: Any?) {
        let tab = activeTab
        guard let previous = tab.back.last else { return }
        let from = tab.path
        go(tab, to: previous) {
            tab.back.removeLast()
            tab.forward.append(from)
        }
    }

    @objc func goForward(_ sender: Any?) {
        let tab = activeTab
        guard let next = tab.forward.last else { return }
        let from = tab.path
        go(tab, to: next) {
            tab.forward.removeLast()
            tab.back.append(from)
        }
    }

    @objc func goUp(_ sender: Any?) {
        guard let parent = activeTab.listing?.parent() else { return }
        navigate(to: parent)
    }

    @objc func goHome(_ sender: Any?) {
        navigate(to: Tab.home)
    }

    @objc func refresh(_ sender: Any?) {
        load(activeTab, keepSelection: true)
    }

    @objc func reload(_ sender: Any?) { refresh(sender) }

    @objc func toggleHidden(_ sender: Any?) {
        showHidden.toggle()
        refresh(nil)
        if splitMode { load(tab(for: focused.other), keepSelection: true) }
        toolbar.update()
    }

    /// Turns what was typed or pasted into Go to Folder into an absolute
    /// path: trims, unquotes, accepts file:// URLs and shell-escaped spaces,
    /// expands ~ and resolves relative paths against `base`.
    static func resolveTypedPath(_ raw: String, relativeTo base: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let f = s.first, f == s.last, f == "'" || f == "\"" { s = String(s.dropFirst().dropLast()) }
        if s.lowercased().hasPrefix("file://"), let url = URL(string: s), url.isFileURL { s = url.path }
        s = s.replacingOccurrences(of: "\\ ", with: " ")
        guard !s.isEmpty else { return nil }
        s = (s as NSString).expandingTildeInPath
        if !s.hasPrefix("/") {
            guard !base.hasPrefix("tag:") else { return nil }
            s = (base as NSString).appendingPathComponent(s)
        }
        return (s as NSString).standardizingPath
    }

    /// Go to Folder "Go": a folder opens, a file opens its folder with the
    /// file selected. Returns false (and says why) if the path is no good.
    @discardableResult
    func goToTypedPath(_ raw: String) -> Bool {
        guard let path = Self.resolveTypedPath(raw, relativeTo: activeTab.path) else {
            NSSound.beep()
            UI.hud("⚠︎ Type a path, e.g. ~/Downloads", in: window)
            return false
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            NSSound.beep()
            UI.hud("⚠︎ No such file or folder: \(path)", in: window)
            return false
        }
        if isDir.boolValue {
            navigate(to: path)
        } else {
            let parent = (path as NSString).deletingLastPathComponent
            navigate(to: parent.isEmpty ? "/" : parent, select: (path as NSString).lastPathComponent)
        }
        window?.makeFirstResponder(panel.focusTarget)
        return true
    }

    /// ⇧⌘G / ⌘L: a sheet with the current folder's path, selected so ⌘C copies
    /// it; type or paste another path and press Go to open it.
    @objc func focusPath(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to Folder"
        alert.informativeText = "This folder's path is selected: ⌘C copies it. Type or paste a path to go somewhere else."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = activeTab.path
        field.lineBreakMode = .byTruncatingHead
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.goToTypedPath(field.stringValue)
        }
        // Once the sheet is up: focus the field with all of its text selected.
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    @objc func toggleFrameMonitor(_ sender: Any?) {
        if frameText.isEmpty {
            frameText = "· measuring…"
            frameMonitor.start(on: panel)
        } else {
            frameMonitor.stop()
            frameText = ""
        }
        updateStatus()
    }

    // MARK: Filter & sort

    /// The filter. In a folder it is a broot pattern and the panel shows
    /// broot's tree of matches under the folder (fuzzy by default, `/re/`
    /// regex, `p/…` path, `c/…` content); tag tabs keep a plain substring
    /// filter. Every keystroke cancels the search still running.
    func setQuery(_ query: String) {
        let tab = activeTab
        guard query != tab.query else { return }
        tab.query = query
        if tab.isVirtual {
            guard let listing = tab.listing else { return }
            listing.setView(field: sortField, descending: sortDescending, query: query)
            tab.resetRows()
            pane(showing: tab)?.panel.reload()
        } else {
            runTreeSearch(tab)
        }
        pane(showing: tab)?.update()
        if tab === leftTab && !splitMode { breadcrumbs.search.show(query) }
        updateStatus()
    }

    /// Rows broot may return per search (UserDefaults "brootMaxRows").
    static var brootMaxRows: UInt32 {
        let v = UserDefaults.standard.integer(forKey: "brootMaxRows")
        return UInt32(v > 0 ? min(v, 100_000) : 500)
    }

    private func cancelTreeSearch(_ tab: Tab) {
        tab.treeSearch?.cancel()
        tab.treeSearch = nil
        tab.treeError = nil
    }

    /// Runs broot for the tab's query off the main thread. A newer query
    /// cancels this one (broot stops within a fraction of a millisecond);
    /// stale results are dropped. An empty query restores the folder.
    private func runTreeSearch(_ tab: Tab, keepSelection: Bool = false) {
        cancelTreeSearch(tab)
        let query = tab.query
        guard !query.isEmpty, !tab.isVirtual, !tab.accessDenied else {
            if let folder = tab.folderListing, tab.listing !== folder {
                tab.listing = folder
                tab.resetRows()
                // Keep the selection where it was: a nested match selects
                // its top-level folder.
                tab.selection = Set(tab.selection.compactMap { $0.split(separator: "/").first.map(String.init) })
                tab.timing = ""
                if let pane = pane(showing: tab) {
                    pane.panel.reload()
                    pane.panel.scrollToSelection()
                    refocusPanel(pane)
                }
            }
            return
        }
        let search = TreeSearch()
        tab.treeSearch = search
        let root = tab.path, hidden = showHidden, maxRows = Self.brootMaxRows
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try search.run(root: root, pattern: query, maxRows: maxRows, showHidden: hidden,
                                                 respectGitIgnore: true, budgetMs: 30_000) }
            DispatchQueue.main.async {
                guard let self, tab.treeSearch === search else { return } // superseded
                tab.treeSearch = nil
                switch result {
                case .success(let listing):
                    tab.listing = listing
                    tab.resetRows()
                    tab.treeError = nil
                    tab.timing = Self.treeTiming(listing)
                    let still = tab.selection.filter { listing.indexOf(name: $0) != nil }
                    if keepSelection && !still.isEmpty {
                        tab.selection = still
                    } else if let best = listing.treeBest(), let row = listing.row(index: best) {
                        tab.selection = [row.name] // broot's best match, like its own selection
                    } else {
                        tab.selection = []
                    }
                case .failure(let error):
                    let message: String
                    switch error as? TreeSearchError {
                    case .Cancelled?: return
                    case .TimedOut?: message = "search took over 30 s, stopped"
                    case .BadPattern(let m)?: message = m
                    case .Failed(let m)?: message = m
                    case nil: message = "\(error)"
                    }
                    // Don't leave an earlier keystroke's results on screen; the empty list shows the error.
                    tab.rows = []
                    tab.selection = []
                    tab.treeError = message
                    tab.timing = "broot: \(message)"
                }
                guard let pane = self.pane(showing: tab) else { return }
                pane.panel.reload()
                pane.panel.scrollToSelection()
                pane.update()
                self.refocusPanel(pane)
                self.selectionDidChange()
            }
        }
    }

    /// Keys typed in a filter field that belong to the list: ↑/↓ move the
    /// selection, Enter opens it (broot's own keys).
    func searchFieldCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
            panel.focusTarget.keyDown(with: event)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            guard !panel.selectedIndexes().isEmpty else { return false }
            openSelection()
            return true
        default:
            return false
        }
    }

    func setSort(_ field: SortField, descending: Bool) {
        sortField = field
        sortDescending = descending
        guard let listing = activeTab.listing, !activeTab.isTree else { return }
        listing.setView(field: field, descending: descending, query: activeTab.query)
        activeTab.resetRows()
        pane(showing: activeTab)?.panel.reload()
    }

    // MARK: Opening

    @objc func openClicked(_ sender: Any?) {
        guard let table = sender as? NSTableView, table.clickedRow >= 0 else { return }
        open(index: table.clickedRow)
    }

    func open(index: Int) {
        let tab = activeTab
        guard let entry = tab.row(index) else { return }
        let path = tab.fullPath(entry.name)
        var isDir: ObjCBool = false
        let folderLike = entry.kind == .folder
            || (entry.kind == .symlink && FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
        if folderLike {
            navigate(to: path)
        } else if Self.isZip(path) {
            ops.extract(path) // our engine; Archive Utility stays under Open With
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private func openSelection() {
        let indexes = panel.selectedIndexes()
        guard let first = indexes.first else { return }
        if let entry = activeTab.row(first), entry.kind == .folder || indexes.count == 1 {
            open(index: first)
        } else {
            for i in indexes { open(index: i) }
        }
    }

    // MARK: Preview

    private func syncPreviewToSelection() {
        previewName = panel.selectedIndexes().first.flatMap { activeTab.row($0)?.name }
        preview.update()
    }

    func stepPreview(_ delta: Int) {
        let tab = activeTab
        guard !tab.rows.isEmpty else { return }
        let current = previewName.flatMap { tab.listing?.indexOf(name: $0) }.map(Int.init) ?? -1
        let next = (current + delta + tab.rows.count) % tab.rows.count
        guard let name = tab.row(next)?.name else { return }
        tab.selection = [name]
        previewName = name
        panel.applySelection()
        if panel.mode == .grid {
            panel.grid.scrollToItems(at: [IndexPath(item: next, section: 0)], scrollPosition: .nearestHorizontalEdge)
        } else {
            panel.list.scrollRowToVisible(next)
        }
        preview.update()
        quickLook.selectionChanged()
        updateStatus()
    }

    // MARK: Keyboard (captools shortcuts, UI-SPEC §14)

    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])
        switch (event.keyCode, mods) {
        case (36, []), (76, []): openSelection(); return true                      // Return
        case (51, []):                                                              // ⌫: edit filter, else parent
            if activeTab.query.isEmpty { goUp(nil) } else { setQuery(String(activeTab.query.dropLast())) }
            return true
        case (117, []), (51, [.command]): moveToBin(nil); return true               // Del / ⌘⌫ (Finder)
        case (51, [.command, .option]), (117, [.command]): deletePermanently(nil); return true
        case (123, [.option]): goBack(nil); return true                             // ⌥←
        case (124, [.option]): goForward(nil); return true                          // ⌥→
        case (126, [.command]): goUp(nil); return true                              // ⌘↑
        case (125, [.command]): openSelection(); return true                        // ⌘↓
        case (96, []): refresh(nil); return true                                    // F5
        case (120, []): renameItem(nil); return true                                // F2
        case (53, []):                                                              // Esc: clear filter, else selection
            if !activeTab.query.isEmpty { setQuery(""); return true }
            activeTab.selection = []; panel.applySelection(); selectionDidChange(); return true
        case (49, []): quickLook.toggle(); return true                              // Space = Quick Look
        case (48, []) where splitMode:                                              // ⇥ = other pane
            focus(focused.other)
            window?.makeFirstResponder(panel.focusTarget)
            return true
        case (48, []), (48, [.shift]):                                              // ⇥ / ⇧⇥ = Explorer
            toggleExplorerFocus(fromExplorer: false)
            return true
        case (121, []): panel.page(1); return true                                  // Page Down
        case (116, []): panel.page(-1); return true                                 // Page Up
        default: break
        }
        // Typing filters live through broot (focus stays on the list, the
        // filter field mirrors the pattern), like typing in broot itself.
        if mods.subtracting(.shift).isEmpty, let typed = event.characters, !typed.isEmpty,
           typed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }) {
            setQuery(activeTab.query + typed)
            return true
        }
        return false
    }

    private lazy var contextMenus = ContextMenuBuilder(fm: self)

    /// Right-click: Finder's item menu when over items, else the folder menu.
    func contextMenu(onItems: Bool) -> NSMenu {
        let paths = selectedPaths()
        return onItems && !paths.isEmpty ? contextMenus.itemMenu(for: paths) : contextMenus.backgroundMenu()
    }

    var currentSort: SortField { sortField }

    @objc func sortMenuChosen(_ sender: NSMenuItem) {
        setSort(sender.tag == 1 ? .kind : sender.tag == 2 ? .size : .name, descending: false)
    }

    static func isZip(_ path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "zip"
    }

    /// Opens files with their default app; a single folder opens in place.
    func openPaths(_ paths: [String]) {
        var isDir: ObjCBool = false
        if paths.count == 1, FileManager.default.fileExists(atPath: paths[0], isDirectory: &isDir), isDir.boolValue,
           (paths[0] as NSString).pathExtension != "app" {
            navigate(to: paths[0])
            return
        }
        for p in paths {
            if Self.isZip(p) { ops.extract(p) } else { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let t = textEditor {
            switch item.action {
            case #selector(copyItems(_:)), #selector(cutItems(_:)), #selector(copyAction(_:)), #selector(cutAction(_:)): return t.selectedRange.length > 0
            case #selector(pasteItems(_:)), #selector(pasteAction(_:)), #selector(selectAllItems(_:)): return true
            case #selector(undoAction(_:)): item.title = "Undo"; return t.undoManager?.canUndo ?? false
            default: break
            }
        }
        switch item.action {
        case #selector(toggleHidden(_:)): item.state = showHidden ? .on : .off
        case #selector(toggleFrameMonitor(_:)): item.state = frameText.isEmpty ? .off : .on
        case #selector(uiZoomIn(_:)): return UIZoom.factor < UIZoom.levels.last! - 0.001
        case #selector(uiZoomOut(_:)): return UIZoom.factor > UIZoom.levels.first! + 0.001
        case #selector(uiZoomReset(_:)): item.title = "Actual Size (\(UIZoom.percent))"
        case #selector(toggleTree(_:)): item.state = showTree ? .on : .off; return !splitMode
        case #selector(toggleSplit(_:)): item.state = splitMode ? .on : .off
        case #selector(togglePreview(_:)): item.state = showPreview ? .on : .off
        case #selector(setListView(_:)): item.state = viewMode == .list ? .on : .off
        case #selector(setGridView(_:)): item.state = viewMode == .grid ? .on : .off
        case #selector(pasteItems(_:)), #selector(pasteAction(_:)): return ops.canPaste && !ops.busy
        case #selector(undoAction(_:)):
            item.title = ops.undoTitle.map { "Undo \($0)" } ?? "Undo"
            return ops.canUndo
        case #selector(redoAction(_:)): return false
        case #selector(copyItems(_:)), #selector(cutItems(_:)), #selector(copyAction(_:)), #selector(cutAction(_:)), #selector(moveToBin(_:)),
             #selector(deletePermanently(_:)), #selector(duplicateItems(_:)):
            return !activeTab.selection.isEmpty && !ops.busy
        case #selector(renameItem(_:)): return activeTab.selection.count == 1 && !ops.busy
        case #selector(goBack(_:)): return !activeTab.back.isEmpty
        case #selector(goForward(_:)): return !activeTab.forward.isEmpty
        default: break
        }
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(panel.focusTarget)
    }

    func windowWillClose(_ notification: Notification) {
        frameMonitor.stop()
    }
}

/// NSSplitView that never draws a divider beside a hidden panel. AppKit
/// otherwise keeps painting it at the hidden panel's old edge — the "ghost
/// line" left after closing the folder tree. (Tint is for debug probes.)
final class TintSplitView: NSSplitView {
    var tint: NSColor?
    override var dividerColor: NSColor { tint ?? super.dividerColor }

    override func drawDivider(in rect: NSRect) {
        let views = arrangedSubviews
        for i in 0..<max(views.count - 1, 0) {
            guard views[i].isHidden || views[i + 1].isHidden else { continue }
            let (start, end) = isVertical ? (rect.minX, rect.maxX) : (rect.minY, rect.maxY)
            let before = isVertical ? views[i].frame.maxX : views[i].frame.maxY
            let after = isVertical ? views[i + 1].frame.minX : views[i + 1].frame.minY
            if abs(before - start) < 1.5 || abs(after - end) < 1.5 { return }
        }
        super.drawDivider(in: rect)
    }
}
