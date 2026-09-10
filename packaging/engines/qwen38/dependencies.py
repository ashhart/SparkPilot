"""Fetch only the reviewed Ubuntu packages needed by the offline image build."""
import hashlib
import json
from pathlib import Path
import re
import urllib.parse
import urllib.request


def allowed_url(url):
    parsed = urllib.parse.urlsplit(url)
    return (parsed.scheme == 'https' and parsed.netloc == 'ports.ubuntu.com'
            and parsed.path.startswith('/ubuntu-ports/pool/')
            and not parsed.query and not parsed.fragment)


class PinnedRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        if not allowed_url(newurl):
            raise RuntimeError('Ubuntu package redirect left the approved archive')
        return super().redirect_request(request, fp, code, message, headers, newurl)


def fetch_package(item, directory, opener):
    name, size, digest = item['filename'], item['bytes'], item['sha256']
    if (not re.fullmatch(r'[A-Za-z0-9.+_~-]+\.deb', name)
            or not allowed_url(item['url'])
            or Path(urllib.parse.urlsplit(item['url']).path).name != name
            or not isinstance(size, int) or not 0 < size <= 16 * 2**20
            or not re.fullmatch(r'[0-9a-f]{64}', digest)):
        raise RuntimeError('Invalid pinned Ubuntu package')
    pending = directory / (name + '.pending')
    try:
        with opener.open(item['url'], timeout=120) as response, pending.open('xb') as output:
            if not allowed_url(response.geturl()):
                raise RuntimeError('Ubuntu package response left the approved archive')
            total, observed = 0, hashlib.sha256()
            while block := response.read(min(1024 * 1024, size - total + 1)):
                total += len(block)
                if total > size:
                    raise RuntimeError('Ubuntu package exceeds its pinned size')
                observed.update(block)
                output.write(block)
        if total != size or observed.hexdigest() != digest:
            raise RuntimeError('Ubuntu package checksum or size mismatch')
        pending.replace(directory / name)
    finally:
        pending.unlink(missing_ok=True)


def fetch(context):
    manifest = json.loads((Path(__file__).parent / 'security-dependencies.json').read_text())
    directory = context / 'security-deps'
    directory.mkdir()
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), PinnedRedirect())
    for item in manifest['packages']:
        fetch_package(item, directory, opener)
