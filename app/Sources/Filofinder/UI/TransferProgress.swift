import AppKit

/// Progress for a copy, move, or duplicate.
///
/// The standard object is `Progress` (NSProgress) with `kind = .file`, the
/// copying operation, and the source file URL, then `publish()`. Finder uses
/// that to draw its file progress (the icon badge and the cancel control).
/// A published progress does not put a progress bar in this window, and the
/// bytes land in a hidden partial name until the copy finishes, so Finder has
/// no destination icon to badge while the work is going on. The panel below is
/// the visible surface: an `NSProgressIndicator` bound with `observedProgress`
/// to that same `Progress`, shown as soon as the operation starts. The copy
/// itself stays on the job queue; this type only touches AppKit on the main thread.
final class TransferProgress: NSObject {
    enum Kind {
        case copy, move, duplicate

        var gerund: String {
            switch self {
            case .copy: "Copying"
            case .move: "Moving"
            case .duplicate: "Duplicating"
            }
        }

        var infinitive: String {
            switch self {
            case .copy: "copy"
            case .move: "move"
            case .duplicate: "duplicate"
            }
        }

        fileprivate var title: String {
            switch self {
            case .copy: "Copy"
            case .move: "Move"
            case .duplicate: "Duplicate"
            }
        }
    }

    /// Status-bar text, already on the main thread.
    var onStatus: ((String) -> Void)?

    private let kind: Kind
    private let progress = Progress(totalUnitCount: -1)
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 148),
                                styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: false)
    private let titleLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let bytes = ByteCountFormatter()
    private let lock = NSLock()
    private var cancelFlag = false
    private var closed = false
    private var published = false
    private var flushQueued = false
    private var pending: Snapshot?

    private struct Snapshot {
        var copied: UInt64
        var total: UInt64
        var currentFile: String
        var itemIndex: Int
        var itemCount: Int
        var itemName: String
    }

    init(kind: Kind) {
        self.kind = kind
        super.init()
        bytes.countStyle = .file
        progress.kind = .file
        progress.fileOperationKind = .copying
        progress.isCancellable = true
        progress.isPausable = false
        progress.localizedDescription = "Preparing to \(kind.infinitive)…"
        progress.cancellationHandler = { [weak self] in self?.cancel() }
        buildPanel()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelFlag
    }

    /// Shows the panel and publishes progress immediately, before any byte is copied.
    func show(over window: NSWindow?, source: URL?) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let source { progress.fileURL = source }
        lock.lock()
        let alreadyPublished = published
        published = true
        lock.unlock()
        if !alreadyPublished { progress.publish() }
        applyText(title: "Preparing to \(kind.infinitive)…", file: source.map { displayName($0.path) } ?? "",
                  detail: "Preparing…")
        if let window {
            place(over: window)
            window.addChildWindow(panel, ordered: .above)
        } else {
            panel.center()
        }
        panel.orderFront(nil)
    }

    func note(copied: UInt64, total: UInt64, currentFile: String, itemIndex: Int, itemCount: Int, itemName: String) {
        lock.lock()
        pending = Snapshot(copied: copied, total: total, currentFile: currentFile,
                           itemIndex: itemIndex, itemCount: itemCount, itemName: itemName)
        let schedule = !flushQueued && !closed
        if schedule { flushQueued = true }
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    func cancel() {
        lock.lock()
        let already = cancelFlag
        cancelFlag = true
        lock.unlock()
        guard !already else { return }
        if !progress.isCancelled { progress.cancel() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stop = self.closed
            self.lock.unlock()
            guard !stop else { return }
            self.titleLabel.stringValue = "Cancelling…"
            self.progress.localizedDescription = "Cancelling…"
            self.onStatus?("Cancelling…")
        }
    }

    func close() {
        dispatchPrecondition(condition: .onQueue(.main))
        lock.lock()
        let already = closed
        closed = true
        let wasPublished = published
        published = false
        lock.unlock()
        guard !already else { return }
        if !isCancelled, progress.totalUnitCount > 0 {
            progress.completedUnitCount = progress.totalUnitCount
            if let count = progress.fileTotalCount { progress.fileCompletedCount = count }
        }
        if wasPublished { progress.unpublish() }
        if let parent = panel.parent { parent.removeChildWindow(panel) }
        panel.orderOut(nil)
    }

    private func flush() {
        lock.lock()
        let snap = pending
        flushQueued = false
        let stop = cancelFlag || closed
        lock.unlock()
        guard let snap, !stop else { return }
        let file = snap.currentFile.isEmpty ? snap.itemName : snap.currentFile
        let name = displayName(file)
        let itemName = snap.itemName.isEmpty ? name : snap.itemName
        let title: String
        let detail: String
        let itemPrefix = snap.itemCount > 1 ? "Item \(snap.itemIndex) of \(snap.itemCount) · " : ""
        if snap.total == 0 {
            title = "Preparing to \(kind.infinitive)…"
            detail = "\(itemPrefix)Preparing…"
            progress.totalUnitCount = -1
            progress.completedUnitCount = 0
        } else {
            title = "\(kind.gerund) “\(itemName)”"
            let copied = min(snap.copied, snap.total)
            detail = "\(itemPrefix)\(bytes.string(fromByteCount: Int64(clamping: copied))) of \(bytes.string(fromByteCount: Int64(clamping: snap.total)))"
            progress.totalUnitCount = Int64(clamping: snap.total)
            progress.completedUnitCount = Int64(clamping: copied)
        }
        if !file.isEmpty { progress.fileURL = URL(fileURLWithPath: file) }
        progress.fileTotalCount = snap.itemCount
        let itemDone = snap.total > 0 && snap.copied >= snap.total
        progress.fileCompletedCount = itemDone ? snap.itemIndex : max(snap.itemIndex - 1, 0)
        progress.localizedDescription = title
        progress.localizedAdditionalDescription = detail
        // While the size is still unknown the title does not name the file, so the
        // second line does. Once copying, the title names the item and the second
        // line names the nested file, if it is a different one.
        let fileLine = snap.total == 0 || name != itemName ? name : ""
        applyText(title: title, file: fileLine, detail: detail)
    }

    private func applyText(title: String, file: String, detail: String) {
        titleLabel.stringValue = title
        fileLabel.stringValue = file
        fileLabel.isHidden = file.isEmpty
        detailLabel.stringValue = detail
        onStatus?(file.isEmpty ? title : "\(title) — \(detail)")
    }

    private func displayName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func place(over window: NSWindow) {
        let host = window.frame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: host.midX - size.width / 2, y: host.minY + 72))
    }

    private func buildPanel() {
        panel.title = kind.title
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileLabel.font = .systemFont(ofSize: 12)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = true
        bar.observedProgress = progress
        bar.startAnimation(nil)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityLabel("Cancel \(kind.infinitive)")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [detailLabel, spacer, cancel])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY

        let stack = NSStackView(views: [titleLabel, fileLabel, bar, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        fileLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bottom.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        panel.contentView = content
    }

    @objc private func cancelClicked() { cancel() }

    deinit {
        // The job queue can drop the last reference off the main thread if the
        // window is already gone. AppKit teardown hops back to the main thread.
        lock.lock()
        let already = closed
        closed = true
        let wasPublished = published
        published = false
        lock.unlock()
        guard !already else { return }
        let progress = progress
        let panel = panel
        DispatchQueue.main.async {
            if wasPublished { progress.unpublish() }
            if let parent = panel.parent { parent.removeChildWindow(panel) }
            panel.orderOut(nil)
        }
    }
}

/// One source item’s bridge to the Rust `ByteProgress` callback.
/// The generated protocol is `ByteProgress`; the callback arrives on the job queue.
final class TransferItemProgress: ByteProgress, @unchecked Sendable {
    private let ui: TransferProgress
    private let index: Int
    private let count: Int
    private let itemName: String

    init(ui: TransferProgress, index: Int, count: Int, itemName: String) {
        self.ui = ui
        self.index = index
        self.count = count
        self.itemName = itemName
    }

    func onBytes(copied: UInt64, total: UInt64, currentFile: String) -> Bool {
        ui.note(copied: copied, total: total, currentFile: currentFile,
                itemIndex: index, itemCount: count, itemName: itemName)
        return !ui.isCancelled
    }
}
