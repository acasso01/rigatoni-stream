#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p media
openssl req -x509 -newkey rsa:2048 -nodes -keyout media/ca-key.pem -out media/ca.pem -days 1 \
  -subj '/CN=Ant Streams Test CA' \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign'
openssl req -newkey rsa:2048 -nodes -keyout media/test-key.pem -out media/server.csr -subj '/CN=localhost'
cat > media/server.ext << 'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1
EOF
openssl x509 -req -in media/server.csr -CA media/ca.pem -CAkey media/ca-key.pem -CAcreateserial \
  -out media/test-cert.pem -days 1 -extfile media/server.ext
if ! command -v ffmpeg >/dev/null; then brew install ffmpeg; fi
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000 -t 18 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 60 -c:a aac -movflags +faststart media/movie.mp4
ffmpeg -hide_banner -loglevel error -y -i media/movie.mp4 -c copy -hls_time 2 -hls_list_size 0 -hls_segment_filename media/segment%03d.ts media/live.m3u8
ffmpeg -hide_banner -loglevel error -y -i media/movie.mp4 -c copy media/movie.mkv
python3 provider.py --cert media/test-cert.pem --key media/test-key.pem > media/server.log 2>&1 &
echo $! > media/server.pid
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sf http://127.0.0.1:8765/health >/dev/null && curl -g -sf 'http://[::1]:8765/health' >/dev/null; then
    exit 0
  fi
  sleep 0.3
done
echo 'Local fixture did not accept both 127.0.0.1 and ::1' >&2
cat media/server.log >&2
exit 1
