# Dropdown playback controls validation

The controller uses the existing status-item menu. The Labs preference defaults to on only when no value has been saved. It does not add Bluetooth sources or change automatic player selection.

Build the Xcode project with its checked-in package resolution, then run on macOS:

```sh
python3 validation/run-playback-checks.py --music-player /path/to/SourcePackages/checkouts/MusicPlayer --output /tmp/lyricsx-controls-probes
```

The probes compile production controller code against public model types from the pinned MusicPlayer checkout. Simulated players cover menu layout, controls, progress timers, artwork precedence, stale results, and source labels. A separate probe covers asynchronous source-query ownership, cancellation, timeout, missing artist metadata, background commands, rapid clicks, and refresh coalescing. Menu probes also hold background seek commands to verify that drag previews survive stale reads and earlier completions, and clear on a track change. These probes do not send commands to real players.

The full app build verifies integration with MusicPlayer and MediaRemoteAdapter. Live checks should also cover Apple Music and a system Now Playing source: expand and close the menu, pause/resume, skip, seek, click the song area, and toggle the Labs setting. Artwork fallback uses an already-authorized running Apple Music or Spotify app; it does not launch another app or request Automation permission just to fetch a cover.
