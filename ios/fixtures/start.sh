#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p media
# Homebrew OpenSSL understands -not_before/-not_after. The system LibreSSL
# does not, and a one-day certificate is evaluated as expired (-9814) when
# the simulator clock is even slightly ahead of the runner.
OPENSSL="$(brew --prefix openssl@3 2>/dev/null || true)/bin/openssl"
if [ ! -x "$OPENSSL" ]; then
  brew install openssl@3
  OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
fi
NOT_BEFORE="$(date -u -v-2d +%Y%m%d%H%M%SZ 2>/dev/null || date -u -d '2 days ago' +%Y%m%d%H%M%SZ)"
NOT_AFTER="$(date -u -v+300d +%Y%m%d%H%M%SZ 2>/dev/null || date -u -d '300 days' +%Y%m%d%H%M%SZ)"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout media/ca-key.pem -out media/ca.pem \
  -subj '/CN=Ant Streams Test CA' \
  -not_before "$NOT_BEFORE" -not_after "$NOT_AFTER" \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -addext 'subjectKeyIdentifier=hash'
"$OPENSSL" req -newkey rsa:2048 -nodes -keyout media/test-key.pem -out media/server.csr -subj '/CN=localhost'
cat > media/server.ext << 'EOF'
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF
"$OPENSSL" x509 -req -in media/server.csr -CA media/ca.pem -CAkey media/ca-key.pem -CAcreateserial \
  -out media/leaf.pem -not_before "$NOT_BEFORE" -not_after "$NOT_AFTER" -extfile media/server.ext
# Leaf first, then the CA, so the simulator can build a chain to the trusted root.
cat media/leaf.pem media/ca.pem > media/test-cert.pem
echo 'Fixture CA:'
"$OPENSSL" x509 -in media/ca.pem -noout -subject -issuer -dates
echo 'Fixture leaf:'
"$OPENSSL" x509 -in media/leaf.pem -noout -subject -issuer -dates
"$OPENSSL" verify -CAfile media/ca.pem media/leaf.pem
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
