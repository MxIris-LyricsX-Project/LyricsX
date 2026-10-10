#!/usr/bin/env python3
"""Offline regression probes. Does not connect devices or control real players."""

import argparse
from pathlib import Path
import platform
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--music-player", type=Path, required=True, help="Pinned MusicPlayer package checkout")
parser.add_argument("--output", type=Path, required=True, help="Directory for executables and logs")
parser.add_argument("--only", nargs="+", help="Run only named probes")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
music = args.music_player.resolve() / "Sources/MusicPlayer"
target = platform.machine() + "-apple-macosx12.0"


def run(name, command):
    log_path = output / (name + ".log")
    with log_path.open("w") as log:
        result = subprocess.run(list(map(str, command)), cwd=root, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        raise SystemExit(f"{name} failed ({result.returncode}); see {log_path}")


def compile_probe(name, sources):
    if args.only and name not in args.only:
        return
    command = ["xcrun", "swiftc", "-target", target, "-module-cache-path", output / "module-cache"]
    command += ["-I", output, "-L", output, "-lMusicPlayer", "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]
    run(name + "-compile", command + sources + ["-o", output / name])
    run(name, [output / name])
    print((output / (name + ".log")).read_text().splitlines()[-1], flush=True)


# Compile the public model types from the locked package, not replacements of
# their behavior. Player implementations are simulated by the probes; a full
# Xcode build and live checks separately cover the production integrations.
model_sources = ["MusicPlayer.swift", "MusicTrack.swift", "PlaybackState.swift", "PlayerName.swift",
                 "Utilities/Typealias.swift", "Players/Agent.swift"]
run("MusicPlayer", ["xcrun", "swiftc", "-target", target, "-emit-library", "-emit-module",
                    "-module-name", "MusicPlayer", "-module-cache-path", output / "module-cache",
                    *[music / path for path in model_sources], "-o", output / "libMusicPlayer.dylib",
                    "-emit-module-path", output / "MusicPlayer.swiftmodule"])

compile_probe("PlaybackMenuProbe", ["LyricsX/Controller/PlaybackArtworkLoader.swift",
                                   "LyricsX/Controller/PlaybackMenuView.swift",
                                   "LyricsX/Controller/PlaybackCommandDispatcher.swift",
                                   "validation/PlaybackMenuProbe.swift"])
compile_probe("PlaybackSourceRequestProbe", ["LyricsX/Controller/PlaybackSourceRequest.swift",
                                            "LyricsX/Controller/PlaybackCommandDispatcher.swift",
                                            "validation/PlaybackSourceRequestProbe.swift"])
