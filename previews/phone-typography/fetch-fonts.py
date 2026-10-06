"""Download pinned upstream font assets and their licenses for this local preview."""
import hashlib
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import quote
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent
FONTS = {
    'inter': ['Inter[opsz,wght].ttf'],
    'ibmplexsans': ['IBMPlexSans[wdth,wght].ttf'],
    'ibmplexmono': ['IBMPlexMono-Regular.ttf', 'IBMPlexMono-Medium.ttf', 'IBMPlexMono-SemiBold.ttf', 'IBMPlexMono-Bold.ttf'],
    'sourcesans3': ['SourceSans3[wght].ttf'],
    'sourcecodepro': ['SourceCodePro[wght].ttf'],
    'atkinsonhyperlegiblenext': ['AtkinsonHyperlegibleNext[wght].ttf'],
    'atkinsonhyperlegiblemono': ['AtkinsonHyperlegibleMono[wght].ttf'],
    'geist': ['Geist[wght].ttf'],
    'geistmono': ['GeistMono[wght].ttf'],
    'manrope': ['Manrope[wght].ttf'],
    'jetbrainsmono': ['JetBrainsMono[wght].ttf'],
    'sourceserif4': ['SourceSerif4[opsz,wght].ttf'],
}

def fetch(job):
    directory, filename, revision = job
    url = f'https://raw.githubusercontent.com/google/fonts/{revision}/ofl/{directory}/{quote(filename)}'
    data = urlopen(url, timeout=30).read()
    destination = ROOT / 'assets' / directory / filename
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    return {'file': str(destination.relative_to(ROOT)), 'url': url, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}

if __name__ == '__main__':
    revision = json.load(urlopen('https://api.github.com/repos/google/fonts/commits/main', timeout=20))['sha']
    jobs = [(directory, filename, revision) for directory, files in FONTS.items() for filename in files + ['OFL.txt']]
    with ThreadPoolExecutor(max_workers=8) as executor:
        manifest = list(executor.map(fetch, jobs))
    (ROOT / 'font-manifest.json').write_text(json.dumps({'google_fonts_revision': revision, 'assets': manifest}, indent=2) + '\n')
    print(f'Downloaded {len(manifest)} assets at {revision}; {sum(x["bytes"] for x in manifest):,} bytes')
