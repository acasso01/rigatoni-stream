#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p media
openssl req -x509 -newkey rsa:2048 -nodes -keyout media/test-key.pem -out media/test-cert.pem -days 1 -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' -addext 'basicConstraints=critical,CA:TRUE' >/dev/null 2>&1
if ! command -v ffmpeg >/dev/null; then brew install ffmpeg; fi
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 18 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 60 -c:a aac -movflags +faststart media/movie.mp4
ffmpeg -hide_banner -loglevel error -y -i media/movie.mp4 -c copy -hls_time 2 -hls_list_size 0 -hls_segment_filename media/segment%03d.ts media/live.m3u8
ffmpeg -hide_banner -loglevel error -y -i media/movie.mp4 -c copy media/movie.mkv
python3 provider.py --cert media/test-cert.pem --key media/test-key.pem >/dev/null 2>&1 &
echo $! > media/server.pid
