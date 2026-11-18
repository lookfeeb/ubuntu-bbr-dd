"""Real HTTP/2, HTTP/3, Brotli and GeoIP2 probe; run only inside nginx_vm's guest."""
import asyncio
from pathlib import Path
import subprocess
import time


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def main():
    if Path('/etc/hostname').read_text().strip() != 'nginx-release-lab':
        raise SystemExit('Run only inside the disposable Nginx validation guest')
    target = Path('/var/www/nginx-probe')
    target.mkdir(parents=True, exist_ok=True)
    body = b'Nginx HTTP2 HTTP3 Brotli GeoIP2 probe.\n' * 4096
    (target / 'probe.txt').write_bytes(body)
    # Reuse the certificate during reinstall/rollback checks. Regenerating it
    # races the old worker during graceful reload and changes the trusted CA.
    if not Path('/etc/nginx/probe.crt').exists():
        run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
            '-keyout', '/etc/nginx/probe.key', '-out', '/etc/nginx/probe.crt', '-subj', '/CN=localhost',
            '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    Path('/etc/nginx/probe.key').chmod(0o600)
    Path('/etc/nginx/conf.d/probe.conf').write_text('''geoip2 /usr/share/GeoIP/GeoLite2-City.mmdb {
    $probe_country default=ZZ country iso_code;
}
server {
    listen 443 ssl;
    listen 443 quic reuseport;
    http2 on;
    server_name localhost;
    ssl_certificate /etc/nginx/probe.crt;
    ssl_certificate_key /etc/nginx/probe.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header X-GeoIP-Country $probe_country always;
    root /var/www/nginx-probe;
}
''')
    config_path = Path('/etc/nginx/nginx.conf')
    config = config_path.read_text()
    if '# nginx-validation-stream' not in config:
        config_path.write_text('load_module /usr/local/nginx/modules/ngx_stream_geoip2_module.so;\n' + config + '''
# nginx-validation-stream
stream {
    geoip2 /usr/share/GeoIP/GeoLite2-City.mmdb {
        $stream_probe_country default=ZZ country iso_code;
    }
    server { listen 127.0.0.1:8443; proxy_pass 127.0.0.1:443; }
}
''')
    run('nginx', '-t')
    run('systemctl', 'reload', 'nginx')
    # Reload signals workers asynchronously; only a not-yet-listening socket is
    # retried. Certificate errors and bad responses remain hard failures.
    for attempt in range(20):
        ready = subprocess.run(['curl', '-fsS', '--cacert', '/etc/nginx/probe.crt',
                                '--connect-to', 'localhost:443:127.0.0.1:8443',
                                'https://localhost/probe.txt'], capture_output=True)
        if ready.returncode != 7:
            ready.check_returncode()
            assert ready.stdout == body
            break
        time.sleep(.1)
    else:
        raise TimeoutError('Stream proxy did not become ready')
    version = subprocess.check_output(['curl', '-fsS', '--cacert', '/etc/nginx/probe.crt', '--http2',
                                      '-w', '%{http_version}', 'https://localhost/probe.txt', '-o', '/tmp/nginx-h2'], text=True)
    assert version == '2' and Path('/tmp/nginx-h2').read_bytes() == body
    run('curl', '-fsS', '--cacert', '/etc/nginx/probe.crt', '-H', 'Accept-Encoding: br', '-D', '/tmp/nginx-br-headers',
        'https://localhost/probe.txt', '-o', '/tmp/nginx-br')
    assert 'content-encoding: br' in Path('/tmp/nginx-br-headers').read_text().lower()
    assert 'x-geoip-country:' in Path('/tmp/nginx-br-headers').read_text().lower()
    run('brotli', '-d', '-f', '/tmp/nginx-br', '-o', '/tmp/nginx-decoded')
    assert Path('/tmp/nginx-decoded').read_bytes() == body
    from aioquic.asyncio import connect, QuicConnectionProtocol
    from aioquic.h3.connection import H3_ALPN, H3Connection
    from aioquic.h3.events import HeadersReceived, DataReceived
    from aioquic.quic.configuration import QuicConfiguration

    class Probe(QuicConnectionProtocol):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.http = H3Connection(self._quic)
            self.done = asyncio.get_running_loop().create_future()
            self.body, self.headers = bytearray(), []

        def quic_event_received(self, event):
            for item in self.http.handle_event(event):
                if isinstance(item, HeadersReceived): self.headers.extend(item.headers)
                if isinstance(item, DataReceived): self.body.extend(item.data)
                if getattr(item, 'stream_ended', False) and not self.done.done(): self.done.set_result(True)

    async def quic():
        config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
        config.load_verify_locations('/etc/nginx/probe.crt')
        async with connect('127.0.0.1', 443, configuration=config, create_protocol=Probe) as protocol:
            stream = protocol._quic.get_next_available_stream_id()
            protocol.http.send_headers(stream, [(b':method', b'GET'), (b':scheme', b'https'),
                                                (b':authority', b'localhost'), (b':path', b'/probe.txt')], end_stream=True)
            protocol.transmit()
            await asyncio.wait_for(protocol.done, 15)
            assert (b':status', b'200') in protocol.headers and bytes(protocol.body) == body

    asyncio.run(quic())
    print('PASS: HTTP/2, verified TLS HTTP/3, Brotli roundtrip, HTTP/stream GeoIP2, stream TLS proxy')


if __name__ == '__main__':
    main()
