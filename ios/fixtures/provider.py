"""Local-only mock IPTV provider. No real content or credentials. Request logging disabled."""
import argparse
import json
import ssl
import threading
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlsplit, parse_qs
from datetime import datetime, timedelta, timezone

class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def send(self, body, content_type='application/json', status=200):
        if not isinstance(body, bytes):
            body = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == '/health':
            return self.send({'ok': True})
        if parsed.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', 'http://localhost:8765/health')
            self.end_headers()
            return
        if parsed.path == '/denied':
            return self.send({}, status=401)
        if parsed.path == '/oversized':
            return self.send(b'x' * 2048, 'text/plain')
        if parsed.path == '/list.m3u':
            return self.send(b'#EXTM3U x-tvg-url="guide.xml"\n#EXTINF:-1 tvg-id="test" group-title="Live",Test live\nmedia/live.m3u8\n#EXTINF:12 group-title="Movies",Test movie\nmedia/movie.mp4\n', 'audio/x-mpegurl')
        if parsed.path == '/guide.xml':
            now = datetime.now(timezone.utc)
            start = (now - timedelta(minutes=5)).strftime('%Y%m%d%H%M%S +0000')
            stop = (now + timedelta(hours=1)).strftime('%Y%m%d%H%M%S +0000')
            return self.send(f'<tv><programme channel="test" start="{start}" stop="{stop}"><title>Test program</title></programme></tv>'.encode(), 'application/xml')
        if parsed.path == '/player_api.php':
            if query.get('username') != ['mock'] or query.get('password') != ['mock']:
                return self.send({'user_info': {'auth': 0}})
            action = query.get('action', [''])[0]
            if not action:
                return self.send({'user_info': {'auth': 1, 'status': 'Active'}})
            if action.endswith('_categories'):
                return self.send([{'category_id': '1', 'category_name': 'Test category'}])
            if action in ['get_live_streams', 'get_vod_streams']:
                return self.send([{'stream_id': 1, 'name': 'Test title', 'category_id': '1', 'container_extension': 'm3u8' if action == 'get_live_streams' else 'mp4'}])
            if action == 'get_series':
                return self.send([{'series_id': 1, 'name': 'Test series', 'category_id': '1'}])
            if action == 'get_series_info':
                return self.send({'episodes': {'1': [{'id': 1, 'episode_num': 1, 'title': 'Test episode', 'container_extension': 'mp4'}]}})
            if action == 'get_vod_info':
                return self.send({'info': {'plot': 'Generated test media', 'releaseDate': '2026-01-01'}})
            if action == 'get_short_epg':
                now = int(datetime.now(timezone.utc).timestamp())
                return self.send({'epg_listings': [{'id': '1', 'title': 'Test program', 'start_timestamp': now - 60, 'stop_timestamp': now + 3600}]})
            return self.send([], status=200)
        if parsed.path.startswith(('/live/mock/mock/', '/movie/mock/mock/', '/series/mock/mock/')):
            self.path = '/media/live.m3u8' if parsed.path.startswith('/live/') else '/media/movie.mp4'
        return super().do_GET()

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--cert', required=True)
    parser.add_argument('--key', required=True)
    args = parser.parse_args()
    http = ThreadingHTTPServer(('127.0.0.1', 8765), Handler)
    https = ThreadingHTTPServer(('127.0.0.1', 8766), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    https.socket = context.wrap_socket(https.socket, server_side=True)
    threading.Thread(target=http.serve_forever, daemon=True).start()
    https.serve_forever()
