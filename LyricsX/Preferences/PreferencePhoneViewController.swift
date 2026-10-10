import AppKit
import Combine

final class PreferencePhoneViewController: PreferenceViewController {
    private let devices = NSPopUpButton(frame: .zero, pullsDown: true)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let artwork = NSImageView()
    private let connectButton = NSButton(title: NSLocalizedString("Connect", comment: "Phone source"), target: nil, action: nil)
    private let disconnectButton = NSButton(title: NSLocalizedString("Disconnect", comment: "Phone source"), target: nil, action: nil)
    private let refresh = NSButton(title: NSLocalizedString("Refresh Devices", comment: "Phone source"), target: nil, action: nil)
    private let reconnect = NSButton(checkboxWithTitle: NSLocalizedString("Reconnect automatically", comment: "Phone source"), target: nil, action: nil)
    private var pairedDevices: [PhonePairedDevice] = []
    private var selectedDevice: PhonePairedDevice?
    private var isRefreshing = false
    private var observation: AnyCancellable?
    private let inventory = PhoneDeviceInventory()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 611, height: 370))
        let heading = NSTextField(labelWithString: "AVRCP")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString: NSLocalizedString("Choose your paired phone. Keep your headphones connected to the phone. LyricsX requests song information and playback controls only.", comment: "Phone source"))
        help.textColor = .secondaryLabelColor
        refresh.target = self; refresh.action = #selector(refreshDevices)
        let settings = NSButton(title: NSLocalizedString("Bluetooth Settings…", comment: "Phone source"), target: self, action: #selector(openBluetoothSettings))
        connectButton.target = self; connectButton.action = #selector(connectPhone)
        disconnectButton.target = self; disconnectButton.action = #selector(disconnectPhone)
        reconnect.target = self; reconnect.action = #selector(changeReconnect)
        reconnect.state = PhonePlayer.shared.autoReconnect ? .on : .off
        let onlineArtwork = NSButton(checkboxWithTitle: NSLocalizedString("Use online artwork when Bluetooth artwork is unavailable", comment: "Phone cover fallback preference"), target: nil, action: nil)
        onlineArtwork.bind(.value, withDefaultName: .phoneOnlineArtworkEnabled)
        onlineArtwork.toolTip = NSLocalizedString("Uses the song title and artist to search for artwork online.", comment: "Phone cover fallback explanation")
        let deviceRow = NSStackView(views: [devices, refresh])
        deviceRow.orientation = .horizontal; deviceRow.spacing = 8
        let commands = NSStackView(views: [connectButton, disconnectButton, settings])
        commands.orientation = .horizontal; commands.spacing = 8
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let compatibility = NSTextField(wrappingLabelWithString: NSLocalizedString("Bluetooth compatibility depends on the phone. Song information and playback position are required. Cover art is shown when the phone supports it; seeking is not available.", comment: "Phone source"))
        compatibility.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        compatibility.textColor = .secondaryLabelColor
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.setAccessibilityLabel(NSLocalizedString("Album Artwork", comment: "Playback artwork"))
        artwork.widthAnchor.constraint(equalToConstant: 40).isActive = true
        artwork.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let playbackRow = NSStackView(views: [artwork, status])
        playbackRow.orientation = .horizontal; playbackRow.spacing = 10
        let stack = NSStackView(views: [heading, help, deviceRow, commands, reconnect, onlineArtwork, playbackRow, compatibility])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            devices.widthAnchor.constraint(equalToConstant: 330),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
            playbackRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            compatibility.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        observation = PhonePlayer.shared.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in self?.updateStatus() }
    }
    override func viewWillAppear() { super.viewWillAppear(); refreshDevices(); updateStatus() }
    @objc private func refreshDevices() {
        guard PhonePlayer.shared.isEnabled else { updateStatus(); return }
        let selected = selectedDevice?.address ?? PhonePlayer.shared.savedAddress
        isRefreshing = true
        inventory.refresh { [weak self] paired in
            guard let self = self, PhonePlayer.shared.isEnabled else { return }
            self.isRefreshing = false
            self.pairedDevices = paired
            self.selectedDevice = paired.first { $0.address == selected } ?? paired.first { $0.isMobile }
            self.updateDeviceMenu()
        }
        updateStatus()
    }

    private func updateDeviceMenu() {
        let menu = NSMenu()
        let title = selectedDevice?.name ?? NSLocalizedString(pairedDevices.isEmpty ? "No paired devices" : "Choose a device", comment: "Phone source")
        // A pull-down's first item is its title, not a selectable device. Keep the
        // selection explicitly so devices chosen from a submenu also work.
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        func item(for device: PhonePairedDevice) -> NSMenuItem {
            let item = NSMenuItem(title: device.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.address
            item.state = device.address == selectedDevice?.address ? .on : .off
            return item
        }
        let mobile = pairedDevices.filter { $0.isMobile }
        let others = pairedDevices.filter { !$0.isMobile }
        for device in mobile { menu.addItem(item(for: device)) }
        if !others.isEmpty {
            if !mobile.isEmpty { menu.addItem(.separator()) }
            let group = NSMenuItem(title: NSLocalizedString("Other paired Bluetooth devices", comment: "Phone source"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for device in others { submenu.addItem(item(for: device)) }
            group.submenu = submenu
            menu.addItem(group)
        }
        devices.menu = menu
        updateStatus()
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String,
              let device = pairedDevices.first(where: { $0.address == address }) else { return }
        selectedDevice = device
        // Let AppKit finish menu tracking before replacing its items.
        DispatchQueue.main.async { [weak self] in self?.updateDeviceMenu() }
    }

    private func updateStatus() {
        let phone = PhonePlayer.shared
        refresh.isEnabled = phone.isEnabled
        reconnect.isEnabled = phone.isEnabled
        if !phone.isEnabled { inventory.cancel(); isRefreshing = false }
        devices.isEnabled = phone.isEnabled && !isRefreshing && !pairedDevices.isEmpty
        artwork.image = phone.currentTrack?.artwork
        artwork.isHidden = artwork.image == nil
        status.stringValue = phone.statusMessage
        if phone.isConnected, let track = phone.currentTrack {
            let metadata = [track.title, track.artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            func time(_ value: TimeInterval) -> String {
                guard value.isFinite, value >= 0 else { return "–:––" }
                let seconds = Int(min(value, Double(Int32.max)))
                return String(format: "%d:%02d", seconds / 60, seconds % 60)
            }
            let progress = time(phone.playbackTime) + " / " + (track.duration.map(time) ?? "–:––")
            status.stringValue += "\n" + metadata + "  " + progress
        }
        if phone.isConnected {
            let key: String
            if phone.isUsingArtworkFallback {
                key = "Bluetooth cover unavailable; online artwork loaded."
            } else {
                switch phone.artworkState {
                case .unavailable: key = "Phone cover art is currently unavailable."
                case .connecting, .loading: key = "Loading phone cover art…"
                case .ready: key = "Waiting for phone cover art…"
                case .loaded: key = "Phone cover art loaded."
                }
            }
            status.stringValue += "\n" + NSLocalizedString(key, comment: "Phone artwork status")
        }
        connectButton.isEnabled = phone.isEnabled && !isRefreshing && selectedDevice != nil && !phone.isConnecting
        disconnectButton.isEnabled = phone.isConnected || phone.isConnecting
    }
    @objc private func connectPhone() {
        guard PhonePlayer.shared.isEnabled, !isRefreshing, let device = selectedDevice else { return }
        let address = device.address
        defaults[.launchAndQuitWithPlayer] = false
        defaults[.loadLyricsBesideTrack] = false
        let name = device.name
        if defaults[.preferredPlayerIndex] == -1 || defaults[.preferredPlayerIndex] == PhonePlayer.preferenceIndex {
            PhonePlayer.shared.connect(address: address, name: name)
        } else {
            PhonePlayer.shared.remember(address: address, name: name)
            defaults[.preferredPlayerIndex] = PhonePlayer.preferenceIndex
        }
        updateStatus()
    }
    @objc private func disconnectPhone() { PhonePlayer.shared.disconnect(); updateStatus() }
    @objc private func changeReconnect() { PhonePlayer.shared.autoReconnect = reconnect.state == .on }
    @objc private func openBluetoothSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }
}
