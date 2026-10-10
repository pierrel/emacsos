"""Produce fixed-weight, distinctly named OFL derivatives for the phone specimen.
Run with fonttools on PYTHONPATH. Original font assets and licenses stay intact.
"""
import hashlib
import json
from pathlib import Path
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = Path(__file__).resolve().parent
JOBS = [
    ('ibmplexsans/IBMPlexSans[wdth,wght].ttf', 'Phone Type 02', [400, 600]),
    ('inter/Inter[opsz,wght].ttf', 'Phone Type 03', [400, 600]),
    ('sourcesans3/SourceSans3[wght].ttf', 'Phone Type 04', [400, 600]),
    ('atkinsonhyperlegiblenext/AtkinsonHyperlegibleNext[wght].ttf', 'Phone Type 05', [400, 600]),
    ('geist/Geist[wght].ttf', 'Phone Type 06', [400, 600]),
    ('manrope/Manrope[wght].ttf', 'Phone Type 07', [400, 600]),
    ('sourceserif4/SourceSerif4[opsz,wght].ttf', 'Phone Type 08', [400, 600]),
    ('ibmplexmono/IBMPlexMono-Regular.ttf', 'Phone Code 02', [400]),
    ('jetbrainsmono/JetBrainsMono[wght].ttf', 'Phone Code 03', [400]),
    ('sourcecodepro/SourceCodePro[wght].ttf', 'Phone Code 04', [400]),
    ('atkinsonhyperlegiblemono/AtkinsonHyperlegibleMono[wght].ttf', 'Phone Code 05', [400]),
    ('geistmono/GeistMono[wght].ttf', 'Phone Code 06', [400]),
]

if __name__ == '__main__':
    out = ROOT / 'phone-fonts'
    out.mkdir(exist_ok=True)
    manifest = []
    for source, family, weights in JOBS:
        for weight in weights:
            font = TTFont(ROOT / 'assets' / source)
            axes = {axis.axisTag: axis.defaultValue for axis in font['fvar'].axes} if 'fvar' in font else {}
            if axes:
                axes['wght'] = weight
                # Text optical sizes, not display designs.
                if 'opsz' in axes:
                    axes['opsz'] = max(next(a.minValue for a in font['fvar'].axes if a.axisTag == 'opsz'), 14)
                font = instantiateVariableFont(font, axes, inplace=True)
            style = 'Regular' if weight == 400 else 'SemiBold'
            ps = family.replace(' ', '') + '-' + style
            names = {1:family,2:style,3:ps+'-Study20261003',4:family+' '+style,6:ps,16:family,17:style,21:family,22:style}
            for key,value in names.items():
                font['name'].removeNames(nameID=key)
                font['name'].setName(value,key,3,1,0x409)
            target = out / (ps + '.ttf')
            font.save(target)
            data = target.read_bytes()
            manifest.append({'file':target.name,'family':family,'weight':weight,'parent':'assets/'+source,'axes':axes,'sha256':hashlib.sha256(data).hexdigest()})
        directory = source.split('/')[0]
        (out / (directory+'-OFL.txt')).write_bytes((ROOT / 'assets' / directory / 'OFL.txt').read_bytes())
    (out / 'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f'Built {len(manifest)} static fonts, {sum((out / x["file"]).stat().st_size for x in manifest):,} bytes')
