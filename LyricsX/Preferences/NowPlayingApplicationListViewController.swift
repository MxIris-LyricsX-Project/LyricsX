//
//  NowPlayingAllowsListViewController.swift
//  LyricsX
//
//  Created by JH on 2025/2/22.
//  Copyright © 2025 ddddxxx. All rights reserved.
//

import AppKit
import SnapKit
import UniformTypeIdentifiers

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
    
    init?(bundleIdentifier: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        self.init(url: url)
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }
    
    static func == (lhs: NowPlayingApplication, rhs: NowPlayingApplication) -> Bool {
        return lhs.bundleIdentifier == rhs.bundleIdentifier
    }
}

final class NowPlayingApplicationListViewController: NSViewController {
    
    enum Section {
        case main
    }
    
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
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
    
    typealias DataSource = NSTableViewDiffableDataSource<Section, NowPlayingApplication>
    
    typealias Snapshot = NSDiffableDataSourceSnapshot<Section, NowPlayingApplication>
    
    let titleLabel = NSTextField(labelWithString: "Now Playing Applications")
    
    let scrollView = NSScrollView()

    let tableView = NSTableView()

    let borderView = NSBox()

    lazy var addButton = NSButton(image: .init(named: NSImage.addTemplateName)!, target: self, action: #selector(addButtonAction(_:)))

    lazy var removeButton = NSButton(image: .init(named: NSImage.removeTemplateName)!, target: self, action: #selector(removeButtonAction(_:)))

    lazy var closeButton = NSButton(title: "Close", target: self, action: #selector(closeButtonAction(_:)))

    lazy var dataSource = makeDataSource()
    
    var applications: [NowPlayingApplication] = [] {
        didSet {
            reloadData()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(titleLabel)
        view.addSubview(borderView)
        borderView.addSubview(scrollView)
        borderView.addSubview(addButton)
        borderView.addSubview(removeButton)
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
            $0.dataSource = dataSource
            $0.delegate = self
            $0.addTableColumn(.init(identifier: .init(rawValue: "Main")))
            $0.rowHeight = 35
        }
        
        borderView.do {
            $0.titlePosition = .noTitle
        }
    
        applications = defaults[.systemWideNowPlayingAppList].compactMap { .init(bundleIdentifier: $0) }
    }

    @objc func addButtonAction(_ sender: NSButton) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.beginSheetModal(for: window) { [weak panel, weak self] response in
            guard let self, let panel, response == .OK else { return }
            applications.append(contentsOf: panel.urls.compactMap(NowPlayingApplication.init))
        }
    }

    @objc func removeButtonAction(_ sender: NSButton) {
        guard !tableView.selectedRowIndexes.isEmpty else { return }
        applications.remove(atOffsets: tableView.selectedRowIndexes)
    }

    @objc func closeButtonAction(_ sender: NSButton) {
        defaults[.systemWideNowPlayingAppList] = applications.map(\.bundleIdentifier)
        dismiss(nil)
    }
    
    func makeDataSource() -> DataSource {
        DataSource(tableView: tableView) { tableView, column, row, application in
            let cellView = tableView.makeView(ofClass: TableCellView.self)
            cellView.iconView.image = application.icon
            cellView.nameLabel.stringValue = application.name
            return cellView
        }
    }
    
    func reloadData() {
        var snapshot = Snapshot()
        snapshot.appendSections([.main])
        snapshot.appendItems(applications, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: true)
    }
}

extension NowPlayingApplicationListViewController: NSTableViewDelegate {
    
    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = !tableView.selectedRowIndexes.isEmpty
    }
}

extension NSTableView {
    func makeView<View: NSView>(ofClass cls: View.Type, owner: Any? = nil) -> View {
        if let view = makeView(withIdentifier: .init(String(describing: cls)), owner: owner) as? View {
            return view
        } else {
            let view = cls.init()
            let identifier = NSUserInterfaceItemIdentifier(String(describing: cls))
            view.identifier = identifier
            return view
        }
    }
}
