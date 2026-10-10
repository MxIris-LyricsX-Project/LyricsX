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


def compile_probe(name, sources, *, model=True, command_args=(), execute=True, bridge=False):
    if args.only and name not in args.only:
        return
    command = ["xcrun", "swiftc", "-target", target, "-module-cache-path", output / "module-cache"]
    if model:
        command += ["-I", output, "-L", output, "-lMusicPlayer", "-Xlinker", "-rpath", "-Xlinker", "@executable_path"]
    if bridge:
        command += ["-import-objc-header", "LyricsX/Phone/PhoneBluetoothCompatibility.h", output / "PhoneBluetoothCompatibility.o"]
    run(name + "-compile", command + sources + ["-o", output / name])
    if execute:
        run(name, [output / name, *command_args])
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

run("BluetoothCompatibility-compile", ["xcrun", "clang", "-mmacosx-version-min=12.0", "-fobjc-arc", "-c",
                                       "LyricsX/Phone/PhoneBluetoothCompatibility.m", "-o", output / "PhoneBluetoothCompatibility.o"])
if not args.only or "PhoneBluetoothCompatibilityProbe" in args.only:
    run("BluetoothCompatibilityProbe-compile", ["xcrun", "clang", "-mmacosx-version-min=12.0", "-fobjc-arc",
                                               "-framework", "Foundation", "-I", "LyricsX/Phone",
                                               "validation/PhoneBluetoothCompatibilityProbe.m",
                                               output / "PhoneBluetoothCompatibility.o", "-o", output / "PhoneBluetoothCompatibilityProbe"])
    run("BluetoothCompatibilityProbe", [output / "PhoneBluetoothCompatibilityProbe"])
    print((output / "BluetoothCompatibilityProbe.log").read_text().strip(), flush=True)

phone = sorted(Path("LyricsX/Phone").glob("*.swift")) + [Path("LyricsX/Component/PlaybackTransitionSource.swift")]
for name in ["PhonePlayerProbe", "PhoneRequestFlowProbe"]:
    compile_probe(name, phone + [Path("validation") / (name + ".swift")], bridge=True)
compile_probe("AutomaticPlayerProbe", ["LyricsX/Component/PlaybackTransitionSource.swift",
                                      "LyricsX/Component/AutomaticPlayer.swift", "validation/AutomaticPlayerProbe.swift"])
compile_probe("PhoneArtworkMetadataProbe", ["LyricsX/Component/PhoneArtworkMetadata.swift",
                                           "LyricsXPackage/Sources/LyricsXFoundation/HighResolutionArtworkPolicy.swift",
                                           "LyricsXPackage/Sources/LyricsXFoundation/StringNormalization.swift",
                                           "validation/PhoneArtworkMetadataProbe.swift"], model=False)
compile_probe("PhoneServiceDiscoveryProbe", ["LyricsX/Phone/PhoneServiceDiscovery.swift",
                                            "validation/PhoneServiceDiscoveryProbe.swift"], model=False, bridge=True)
# The supervisor probe launches this synthetic child, never a Bluetooth worker.
if not args.only or "PhoneWorkerIsolationProbe" in args.only:
    saved_only = args.only
    args.only = None
    compile_probe("PhoneWorkerFaultFixture", phone + [Path("validation/PhoneWorkerFaultFixture.swift")], execute=False, bridge=True)
    args.only = saved_only
compile_probe("PhoneWorkerIsolationProbe", phone + [Path("validation/PhoneWorkerIsolationProbe.swift")],
              command_args=[output / "PhoneWorkerFaultFixture"], bridge=True)
compile_probe("PhoneDiagnosticsProbe", ["LyricsX/Phone/PhoneDiagnostics.swift", "validation/PhoneDiagnosticsProbe.swift"], model=False)
