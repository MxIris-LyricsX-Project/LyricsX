"""Count sideways jumps of the desktop lyrics box in a screen recording.

The desktop lyrics box is centred on a fixed x, so its centre should never
move, not even while it grows or shrinks for a new line. Every frame whose
centre differs from the previous frame's by at least the threshold counts as
a jump. The box is found by colour, so set the desktop lyrics background to
opaque magenta (#FF00FF) before recording.

Record only the strip the box sits in, on a Retina display:
    screencapture -x -V 20 -R <x>,<y>,<width>,<height> box.mov

Usage: python3 -I Scripts/count-desktop-lyrics-box-jumps.py box.mov [threshold-points]
Needs ffmpeg and ffprobe on PATH. The video is scaled to half size, so one
pixel is one point. Exit code 1 when any jump is found, 0 otherwise. The
first frames after the box appears (fading and sliding in) count as jumps;
start recording while lyrics are already showing.

Why this exists: Documentations/Internal/DesktopLyrics.md.
"""
import statistics
import subprocess
import sys

videoPath = sys.argv[1]
thresholdPoints = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

probe = subprocess.run(
    ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height',
     '-of', 'csv=p=0', videoPath],
    capture_output=True, text=True, check=True,
).stdout.strip().split(',')
videoWidth, videoHeight = int(probe[0]), int(probe[1])
scaledWidth, scaledHeight = videoWidth // 2, videoHeight // 2

frameTimes = [
    float(line.strip().rstrip(','))
    for line in subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=pts_time',
         '-of', 'csv=p=0', videoPath],
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    if line.strip().rstrip(',')
]
rawFrames = subprocess.run(
    ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', videoPath, '-fps_mode', 'passthrough',
     '-vf', f'scale={scaledWidth}:{scaledHeight}', '-pix_fmt', 'rgb24', '-f', 'rawvideo', '-'],
    capture_output=True, check=True,
).stdout

frameSize = scaledWidth * scaledHeight * 3
centers = []
for frameIndex in range(len(rawFrames) // frameSize):
    frame = rawFrames[frameIndex * frameSize:(frameIndex + 1) * frameSize]
    magentaColumns = []
    for row in range(scaledHeight):
        rowOffset = row * scaledWidth * 3
        for column in range(scaledWidth):
            pixelOffset = rowOffset + column * 3
            red, green, blue = frame[pixelOffset], frame[pixelOffset + 1], frame[pixelOffset + 2]
            if red > 170 and blue > 170 and green < 110:
                magentaColumns.append(column)
    if magentaColumns:
        centers.append((min(magentaColumns) + max(magentaColumns)) / 2)
    else:
        centers.append(None)

presentCenters = [center for center in centers if center is not None]
if not presentCenters:
    print('no magenta box found')
    sys.exit(2)

medianCenter = statistics.median(presentCenters)
jumps = []
for index in range(1, len(centers)):
    previous, current = centers[index - 1], centers[index]
    if previous is None or current is None:
        continue
    if abs(current - previous) >= thresholdPoints:
        time = frameTimes[index] if index < len(frameTimes) else float(index)
        jumps.append((time, current - previous, current - medianCenter))

offCenterFrames = sum(1 for center in presentCenters if abs(center - medianCenter) >= thresholdPoints)
print(f'frames={len(centers)} boxFrames={len(presentCenters)} median={medianCenter:.1f} '
      f'offCenterFrames={offCenterFrames} jumps={len(jumps)}')
for time, shift, offset in jumps:
    print(f'  {time:6.2f}s shift {shift:+5.1f} pt, now {offset:+5.1f} pt from median')
sys.exit(1 if jumps else 0)
