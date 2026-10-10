# Bluetooth AVRCP source validation

AVRCP is opt-in in Labs. Disabling it removes both preference entry points, stops workers, and restores upstream local source selection. The phone keeps its audio output; LyricsX requests metadata and playback commands, not an audio profile. Online artwork fallback has a separate setting in the AVRCP pane and runs only after Bluetooth reports no usable cover service or image handle.

Build the Xcode project with its checked-in package resolution, then run on macOS:

```sh
python3 validation/run-avrcp-checks.py --music-player /path/to/SourcePackages/checkouts/MusicPlayer --output /tmp/lyricsx-avrcp-probes
```

The runner compiles production feature files with model types from the pinned MusicPlayer source. It does not connect a real device. Probes cover protocol parsing, notification and request lifecycles, stale replies, track transitions, automatic source selection, background refreshes, SDP parsing, artwork matching, diagnostic limits, and worker failures. The worker supervisor probe launches a synthetic child process and checks UI responsiveness; its callback count is not display FPS.

## Compatibility boundary

Native IOBluetooth is the normal transport. On Apple Silicon running macOS 27 only, a worker-local workaround can fill missing L2CAP callbacks through undocumented selectors. It validates getter/setter signatures before installation and the forwarded signature before each delivery; existing callbacks are never replaced. A missing or changed interface is skipped and normal connection failure handling remains in effect. This is a private-API maintenance risk, not a guarantee of support across OS releases. The Objective-C probe exercises missing, existing, forwarded, and incompatible callbacks without a real device.

Bluetooth artwork additionally requires the peer's advertised AVRCP Cover Art service and a valid image handle. An online cover is not evidence of Bluetooth image transfer. Seeking is not implemented. Live verification is still needed for each claimed device/OS combination, reconnection, track changes, audio routing, and the two artwork settings operating independently.

Diagnostics are off unless a temporary `lyricsx-phone-diagnostics-enabled` file exists. Its modification time limits the session to 15 minutes; each process log stops at 1 MiB. Protocol logging omits addresses and song metadata values.
