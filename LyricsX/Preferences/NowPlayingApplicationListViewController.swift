import AppKit
import CoreServices
import MediaRemoteAdapter
import SnapKit
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

struct NowPlayingApplication: Hashable {
    let name: String
    let icon: NSImage
    let bundleIdentifier: String

    init?(url: URL) {
        guard let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else { return nil }
        self.name = FileManager.default.displayName(atPath: url.path)
        self.icon = NSWorkspace.shared.icon(forFile: url.path)
        self.bundleIdentifier = bundleIdentifier
    }

    init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        let resolvedURL = NowPlayingApplication.resolveApplicationURL(for: bundleIdentifier)
        if let resolvedURL {
            self.name = FileManager.default.displayName(atPath: resolvedURL.path)
            self.icon = NSWorkspace.shared.icon(forFile: resolvedURL.path)
        } else {
            self.name = bundleIdentifier
            if #available(macOS 11.0, *) {
                self.icon = NSWorkspace.shared.icon(for: .applicationBundle)
            } else {
                self.icon = NSWorkspace.shared.icon(forFileType: kUTTypeApplicationBundle as String)
            }
        }
    }

    // MediaRemote reports the source app's bundle id as `<iOS-bid>.<TeamID>`
    // for iOS-on-Mac / iOS-embedded clients (10-char uppercase alphanumeric
    // suffix). Those identifiers never resolve via NSWorkspace, so we strip
    // the suffix to surface the wrapper macOS app's icon and display name —
    // purely a cosmetic fallback; the canonical bundleIdentifier stored on
    // the struct keeps the original value used by MediaRemote filtering.
    private static func resolveApplicationURL(for bundleIdentifier: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        if let stripped = stripTeamIdentifierSuffix(from: bundleIdentifier),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: stripped) {
            return url
        }
        return nil
    }

    private static func stripTeamIdentifierSuffix(from bundleIdentifier: String) -> String? {
        guard let dotIndex = bundleIdentifier.lastIndex(of: ".") else { return nil }
        let suffix = bundleIdentifier[bundleIdentifier.index(after: dotIndex)...]
        guard suffix.count == 10,
              suffix.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            return nil
        }
        return String(bundleIdentifier[..<dotIndex])
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }

    static func == (lhs: NowPlayingApplication, rhs: NowPlayingApplication) -> Bool {
        return lhs.bundleIdentifier == rhs.bundleIdentifier
    }
}

final class NowPlayingApplicationListViewController: NSViewController {
    class TableCellView: NSTableCellView {
        let iconView = NSImageView()

        let nameLabel = NSTextField(labelWithString: "")

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            addSubview(iconView)
            addSubview(nameLabel)

            iconView.snp.makeConstraints { make in
                make.left.centerY.equalToSuperview()
                make.size.equalTo(20)
            }

            nameLabel.snp.makeConstraints { make in
                make.left.equalTo(iconView.snp.right).offset(5)
                make.centerY.equalToSuperview()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    let titleLabel = NSTextField(labelWithString: "Now Playing Applications")

    let scrollView = NSScrollView()

    let tableView = NSTableView()

    let borderView = NSBox()

    lazy var addButton = NSButton(image: .init(named: NSImage.addTemplateName)!, target: self, action: #selector(addButtonAction(_:)))

    lazy var removeButton = NSButton(image: .init(named: NSImage.removeTemplateName)!, target: self, action: #selector(removeButtonAction(_:)))

    lazy var addCurrentPlayingButton = NSButton(title: NSLocalizedString("Add Current Playing", comment: "Button on the NowPlaying whitelist editor that captures the currently playing app's bundle id from MediaRemote."), target: self, action: #selector(addCurrentPlayingButtonAction(_:)))

    lazy var closeButton = NSButton(title: "Close", target: self, action: #selector(closeButtonAction(_:)))

    var applications: [NowPlayingApplication] = [] {
        didSet {
            tableView.reloadData()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(titleLabel)
        view.addSubview(borderView)
        borderView.addSubview(scrollView)
        borderView.addSubview(addButton)
        borderView.addSubview(removeButton)
        borderView.addSubview(addCurrentPlayingButton)
        view.addSubview(closeButton)

        titleLabel.snp.makeConstraints { make in
            make.top.equalToSuperview().inset(20)
            make.left.equalToSuperview().inset(20)
        }

        borderView.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(10)
            make.left.right.equalToSuperview().inset(20)
            make.bottom.equalTo(closeButton.snp.top).offset(-20)
        }

        addButton.snp.makeConstraints { make in
            make.left.bottom.equalToSuperview()
            make.size.equalTo(30)
        }

        removeButton.snp.makeConstraints { make in
            make.left.equalTo(addButton.snp.right)
            make.bottom.equalToSuperview()
            make.size.equalTo(30)
        }

        addCurrentPlayingButton.snp.makeConstraints { make in
            make.left.equalTo(removeButton.snp.right).offset(10)
            make.centerY.equalTo(addButton)
        }

        scrollView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
            make.bottom.equalTo(addButton.snp.top).offset(-10)
        }

        closeButton.snp.makeConstraints { make in
            make.bottom.equalToSuperview().inset(20)
            make.right.equalToSuperview().inset(20)
            make.width.greaterThanOrEqualTo(80)
        }

        titleLabel.do {
            $0.font = .systemFont(ofSize: 18, weight: .regular)
        }

        addButton.do {
            $0.isBordered = false
        }

        removeButton.do {
            $0.isBordered = false
            $0.isEnabled = false
        }

        scrollView.do {
            $0.drawsBackground = false
            $0.backgroundColor = .clear
            $0.documentView = tableView
            $0.scrollerStyle = .overlay
        }

        tableView.do {
            $0.headerView = nil
            $0.backgroundColor = .clear
            $0.dataSource = self
            $0.delegate = self
            $0.addTableColumn(.init(identifier: .init(rawValue: "Main")))
            $0.rowHeight = 35
        }

        borderView.do {
            $0.titlePosition = .noTitle
        }

        var seenBundleIdentifiers = Set<String>()
        applications = defaults[.systemWideNowPlayingAppList]
            .filter { seenBundleIdentifiers.insert($0).inserted }
            .map { .init(bundleIdentifier: $0) }
    }

    @objc func addButtonAction(_ sender: NSButton) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.application]
        } else {
            panel.allowedFileTypes = ["app"]
        }
        panel.beginSheetModal(for: window) { [weak panel, weak self] response in
            guard let self, let panel, response == .OK else { return }
            let existingBundleIdentifiers = Set(applications.map(\.bundleIdentifier))
            let newApplications = panel.urls
                .compactMap(NowPlayingApplication.init)
                .filter { !existingBundleIdentifiers.contains($0.bundleIdentifier) }
            applications.append(contentsOf: newApplications)
        }
    }

    @objc func removeButtonAction(_ sender: NSButton) {
        guard !tableView.selectedRowIndexes.isEmpty else { return }
        applications.remove(atOffsets: tableView.selectedRowIndexes)
    }

    // Captures the bundle identifier MediaRemote actually reports for the
    // current NowPlaying client. Required for sources whose MediaRemote-side
    // identity diverges from the on-disk `.app`'s bundle identifier — most
    // notably iOS-on-Mac / iOS-embedded subprocesses, which report
    // `<iOS-bid>.<TeamID>` (e.g. `com.tencent.QQMusic.D5Q73692VW` from
    // QQMusic's embedded iOS process) while NSOpenPanel only sees the
    // wrapper macOS app's bundle id (`com.tencent.QQMusicMac`). The probe
    // uses a one-shot MediaController with no `--id` filter so it observes
    // every client, regardless of the host LyricsX whitelist.
    private var currentPlayingProbe: MediaController?

    @objc func addCurrentPlayingButtonAction(_ sender: NSButton) {
        sender.isEnabled = false
        let probe = MediaController(bundleIdentifiers: [])
        currentPlayingProbe = probe
        var didFinish = false
        probe.onTrackInfoReceived = { [weak self, weak sender] trackInfo, _ in
            DispatchQueue.main.async {
                guard !didFinish else { return }
                didFinish = true
                sender?.isEnabled = true
                guard let self else { return }
                self.currentPlayingProbe = nil
                if let bundleIdentifier = trackInfo?.bundleIdentifier, !bundleIdentifier.isEmpty {
                    let application = NowPlayingApplication(bundleIdentifier: bundleIdentifier)
                    if !self.applications.contains(application) {
                        self.applications.append(application)
                    }
                } else {
                    self.presentNoCurrentPlayingAlert()
                }
            }
        }
        probe.updatePlayerState()
    }

    private func presentNoCurrentPlayingAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("No active NowPlaying source", comment: "Title for the alert shown when LyricsX cannot find a currently playing app while resolving its bundle id.")
        alert.informativeText = NSLocalizedString("Start playback in the app you want to add, then try again.", comment: "Body for the no-active-NowPlaying-source alert.")
        alert.runModal()
    }

    @objc func closeButtonAction(_ sender: NSButton) {
        defaults[.systemWideNowPlayingAppList] = applications.map(\.bundleIdentifier)
        dismiss(nil)
    }
}

extension NowPlayingApplicationListViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return applications.count
    }
}

extension NowPlayingApplicationListViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellView = tableView.box.makeView(ofClass: TableCellView.self)
        let application = applications[row]
        cellView.iconView.image = application.icon
        cellView.nameLabel.stringValue = application.name
        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }
}
