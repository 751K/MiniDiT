#!/bin/sh
# Synthetic media only. Refuse overwriting an existing fixture.
set -eu
FIXTURE_DIR=${1:?Pass a new fixture directory}
FFMPEG_BIN=${FFMPEG_BIN:-ffmpeg}
mkdir -p "$FIXTURE_DIR"
"$FFMPEG_BIN" -hide_banner -loglevel error -n -f lavfi -i 'testsrc2=size=320x180:rate=25:duration=5' -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=5' -c:v libx264 -pix_fmt yuv420p -c:a aac -metadata creation_time=2025-01-02T03:04:05Z "$FIXTURE_DIR/source.mp4"
"$FFMPEG_BIN" -hide_banner -loglevel error -n -display_rotation:v:0 90 -i "$FIXTURE_DIR/source.mp4" -c copy "$FIXTURE_DIR/portrait.mov"
"$FFMPEG_BIN" -hide_banner -loglevel error -n -f lavfi -i 'testsrc2=size=320x180:rate=30:duration=0.8' -c:v libx264 -pix_fmt yuv420p "$FIXTURE_DIR/short.mp4"
"$FFMPEG_BIN" -hide_banner -loglevel error -n -f lavfi -i 'testsrc2=size=320x180:rate=30:duration=0.2' -c:v libx264 -pix_fmt yuv420p "$FIXTURE_DIR/tiny.mp4"
"$FFMPEG_BIN" -hide_banner -loglevel error -n -f lavfi -i 'testsrc2=size=320x180:rate=50:duration=4' -c:v libx265 -x265-params log-level=error -pix_fmt yuv420p10le -tag:v hvc1 -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc "$FIXTURE_DIR/hlg.mp4"
