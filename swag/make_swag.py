"""
make_swag — Print files for the dranglpak64 Roboexotica swag.

Writes to out/ (text converted to paths, so print shops don't need the font):
    tshirt-flex.svg           Flex print, one layer per foil (Silber, Grau, Orange)
    tshirt-flex-<foil>.svg    The same, one cut file per foil
    tshirt-flex-preview.svg   How the flex print looks on the black shirt
    tshirt-dtf.svg            Full chrome logo for DTF/digital transfer print
    sticker-cabinet.svg       Logo + QR code to the live dashboard, for the cabinet
    sticker-logo.svg          Logo sticker for visitors to take home
Also writes ../web/logo.svg and ../web/favicon.svg for the dashboard.

Usage (from this directory):
    nix-shell -p 'python3.withPackages (ps: [ ps.fonttools ps.uharfbuzz ps.segno ps.skia-pathops ])' \
        --run 'python3 make_swag.py'
"""

from pathlib import Path

import pathops
import segno
import uharfbuzz as hb
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

HERE = Path(__file__).parent
FONT_PATH = HERE / "fonts" / "RussoOne-Regular.ttf"
FONT = TTFont(FONT_PATH)
OUT = HERE / "out"

URL = "https://dranglpak64.knedlsepp.at"

UPEM = FONT["head"].unitsPerEm
CAP = FONT["OS/2"].sCapHeight

# Logo: "DranglPak" plus "64" at half size, top-aligned to the caps
LOGO_MAIN = "DranglPak"
LOGO_SUP = "64"
SUP_SCALE = 0.5
SUP_GAP = 0.04 * UPEM
# Extrusion down right, outline around everything (font units)
EXTRUDE = (0.06 * UPEM, -0.09 * UPEM)
EXTRUDE_STEPS = 14
OUTLINE = 0.035 * UPEM

CHROME = [(0, "#6b7280"), (0.45, "#f4f6fb"), (0.5, "#8a93a6"), (0.75, "#dfe4ee"), (1, "#ffffff")]
FIRE = [(0, "#d91e1e"), (1, "#ffb000")]
EXTRUDE_COLOR = "#2b2f3a"
OUTLINE_COLOR = "#0b0c10"
BLACK = "#000000"
WHITE = "#ffffff"

# Flex foils (name, preview colour). Grey runs this far under the silver, so
# no gap shows between the foils after pressing.
FLEX_FOILS = {"Silber": "#c9ced8", "Grau": "#5b6170", "Orange": "#ff8a00"}
FLEX_OVERLAP_MM = 0.3


def shape(text: str, pen, scale: float = 1.0, dx: float = 0.0, dy: float = 0.0) -> float:
    """Draw shaped (kerned) text into pen. Returns its advance in font units."""
    buf = hb.Buffer()
    buf.add_str(text)
    buf.guess_segment_properties()
    hb.shape(hb.Font(hb.Face(hb.Blob.from_file_path(str(FONT_PATH)))), buf, {"kern": True})
    glyph_set, order = FONT.getGlyphSet(), FONT.getGlyphOrder()
    x = 0
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        glyph_set[order[info.codepoint]].draw(
            TransformPen(pen, (scale, 0, 0, scale, dx + (x + pos.x_offset) * scale, dy + pos.y_offset * scale))
        )
        x += pos.x_advance
    return x * scale


def shape_path(text: str, **kwargs) -> pathops.Path:
    path = pathops.Path()
    shape(text, path.getPen(), **kwargs)
    path.simplify()
    return path


def svg_d(path: pathops.Path) -> str:
    pen = SVGPathPen(None)
    path.draw(pen)
    return pen.getCommands()


def translated(path: pathops.Path, dx: float, dy: float) -> pathops.Path:
    result = pathops.Path()
    path.draw(TransformPen(result.getPen(), (1, 0, 0, 1, dx, dy)))
    return result


def union(*paths: pathops.Path) -> pathops.Path:
    result = pathops.Path()
    pathops.union(paths, result.getPen())
    return result


def stroked(path: pathops.Path, width: float) -> pathops.Path:
    result = pathops.Path()
    result.addPath(path)
    result.stroke(width, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
    # Round joins come out as conics, which path operations can't handle
    result.convertConicsToQuads()
    return result


class Logo:
    """Logo geometry in font units (y up). Other texts in the same style, e.g. for the favicon."""

    def __init__(self, main: str = LOGO_MAIN, sup: str = LOGO_SUP) -> None:
        self.main = shape_path(main)
        advance = shape(main, pathops.Path().getPen())
        self.sup = shape_path(sup, scale=SUP_SCALE, dx=advance + SUP_GAP, dy=CAP * (1 - SUP_SCALE))
        self.face = union(self.main, self.sup)
        self.extrusion = union(*(
            translated(self.face, EXTRUDE[0] * i / EXTRUDE_STEPS, EXTRUDE[1] * i / EXTRUDE_STEPS)
            for i in range(1, EXTRUDE_STEPS + 1)
        ))
        self.body = union(self.face, self.extrusion)
        x0, y0, x1, y1 = self.body.bounds
        self.bounds = (x0 - OUTLINE, y0 - OUTLINE, x1 + OUTLINE, y1 + OUTLINE)

    @property
    def aspect(self) -> float:
        x0, y0, x1, y1 = self.bounds
        return (y1 - y0) / (x1 - x0)

    def place(self, body: str, x: float, y: float, width: float) -> str:
        """Font unit SVG with the logo's top left corner at (x, y) mm, width mm wide."""
        x0, _, x1, y1 = self.bounds
        k = width / (x1 - x0)
        return f'<g transform="matrix({k:g} 0 0 {-k:g} {x - x0 * k:g} {y + y1 * k:g})">{body}</g>'

    def chrome(self, uid: str) -> str:
        """Full colour logo: extrusion, outline, chrome faces with gloss."""
        main, sup = svg_d(self.main), svg_d(self.sup)
        layers = [
            (EXTRUDE[0] * i / EXTRUDE_STEPS, EXTRUDE[1] * i / EXTRUDE_STEPS)
            for i in range(EXTRUDE_STEPS, 0, -1)
        ]
        shifted = "".join(
            f'<path transform="translate({dx:g} {dy:g})" d="{main}"/><path transform="translate({dx:g} {dy:g})" d="{sup}"/>'
            for dx, dy in layers
        )
        return (
            "<defs>"
            + gradient(f"chrome-{uid}", CHROME)
            + gradient(f"fire-{uid}", FIRE)
            + gradient(f"gloss-{uid}", [(0.5, "#ffffff", 0.55), (0.52, "#ffffff", 0)])
            + "</defs>"
            + f'<path fill="{OUTLINE_COLOR}" stroke="{OUTLINE_COLOR}" stroke-width="{2 * OUTLINE:g}" '
            + f'stroke-linejoin="round" d="{svg_d(self.body)}"/>'
            + f'<g fill="{EXTRUDE_COLOR}">{shifted}</g>'
            + f'<path fill="url(#chrome-{uid})" stroke="{OUTLINE_COLOR}" stroke-width="{0.6 * OUTLINE:g}" d="{main}"/>'
            + f'<path fill="url(#fire-{uid})" stroke="{OUTLINE_COLOR}" stroke-width="{0.6 * OUTLINE:g}" d="{sup}"/>'
            + f'<path fill="url(#gloss-{uid})" d="{main}"/><path fill="url(#gloss-{uid})" d="{sup}"/>'
        )

    def flex_foils(self, overlap: float) -> dict[str, pathops.Path]:
        """Solid areas per foil, side by side instead of stacked (font units)."""
        eroded_face = pathops.op(self.face, stroked(self.face, 2 * overlap), pathops.PathOp.DIFFERENCE)
        return {
            "Silber": self.main,
            "Grau": pathops.op(self.extrusion, eroded_face, pathops.PathOp.DIFFERENCE),
            "Orange": self.sup,
        }


def gradient(gid: str, stops: list) -> str:
    """Vertical gradient, offset 0 at the bottom (font units are y up)."""
    return (
        f'<linearGradient id="{gid}" x1="0" y1="1" x2="0" y2="0">'
        + "".join(
            f'<stop offset="{s[0]}" stop-color="{s[1]}"' + (f' stop-opacity="{s[2]}"' if len(s) > 2 else "") + "/>"
            for s in stops
        )
        + "</linearGradient>"
    )


def text(s: str, x: float, y: float, cap_height: float, color: str, center: bool = False) -> str:
    """Text with its baseline at y mm and caps cap_height mm tall."""
    k = cap_height / CAP
    path = shape_path(s)
    x0, _, x1, _ = path.bounds
    if center:
        x -= (x1 - x0) * k / 2
    return f'<path fill="{color}" transform="matrix({k:g} 0 0 {-k:g} {x - x0 * k:g} {y:g})" d="{svg_d(path)}"/>'


def qr(x: float, y: float, width: float) -> str:
    """QR code including its quiet zone, black on white, as a single path."""
    matrix = list(segno.make(URL, error="m").matrix_iter(scale=1, border=4))
    module = width / len(matrix)
    d = []
    for row, line in enumerate(matrix):
        col = 0
        while col < len(line):
            if line[col]:
                start = col
                while col < len(line) and line[col]:
                    col += 1
                w = (col - start) * module
                d.append(f"M{x + start * module:g} {y + row * module:g}h{w:g}v{module:g}h{-w:g}z")
            else:
                col += 1
    return f'<rect x="{x:g}" y="{y:g}" width="{width:g}" height="{width:g}" fill="{WHITE}"/><path fill="{BLACK}" d="{"".join(d)}"/>'


def svg(width: float, height: float, body: str) -> str:
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:g}mm" height="{height:g}mm" '
        f'viewBox="0 0 {width:g} {height:g}">{body}</svg>\n'
    )


TSHIRT_WIDTH, TSHIRT_MARGIN = 280, 5


def tshirt_canvas(logo: Logo) -> tuple[float, float]:
    return TSHIRT_WIDTH + 2 * TSHIRT_MARGIN, TSHIRT_WIDTH * logo.aspect + 2 * TSHIRT_MARGIN


def tshirt_flex(logo: Logo) -> dict[str, str]:
    """28 cm wide. The black outline is left out: that's the shirt."""
    width, height = tshirt_canvas(logo)
    x0, _, x1, _ = logo.bounds
    overlap = FLEX_OVERLAP_MM / (TSHIRT_WIDTH / (x1 - x0))
    foils = logo.flex_foils(overlap)

    def layer(name: str) -> str:
        body = f'<path fill="{FLEX_FOILS[name]}" d="{svg_d(foils[name])}"/>'
        return f'<g id="{name}">{logo.place(body, TSHIRT_MARGIN, TSHIRT_MARGIN, TSHIRT_WIDTH)}</g>'

    files = {f"tshirt-flex-{name.lower()}": svg(width, height, layer(name)) for name in FLEX_FOILS}
    # Grey first: it runs under the silver
    layers = "".join(layer(name) for name in ["Grau", "Silber", "Orange"])
    files["tshirt-flex"] = svg(width, height, layers)
    files["tshirt-flex-preview"] = svg(width, height, f'<rect width="100%" height="100%" fill="{BLACK}"/>' + layers)
    return files


def tshirt_dtf(logo: Logo) -> str:
    width, height = tshirt_canvas(logo)
    return svg(width, height, logo.place(logo.chrome("dtf"), TSHIRT_MARGIN, TSHIRT_MARGIN, TSHIRT_WIDTH))


def sticker_cabinet(logo: Logo) -> str:
    """20 x 20 cm for the front of a 25 x 25 cm Rittal AX cabinet."""
    size, margin = 200, 12
    body = f'<rect width="{size}" height="{size}" rx="12" fill="{BLACK}"/>'
    body += logo.place(logo.chrome("cabinet"), margin, 12, size - 2 * margin)
    body += text("LIVE MITSCHAUEN", size / 2, 52, 5, "#9aa3b5", center=True)
    qr_width = 112
    body += f'<rect x="{(size - qr_width) / 2 - 2:g}" y="58" width="{qr_width + 4}" height="{qr_width + 4}" rx="4" fill="{WHITE}"/>'
    body += qr((size - qr_width) / 2, 60, qr_width)
    body += text(URL.removeprefix("https://"), size / 2, 188, 8, WHITE, center=True)
    return svg(size, size, body)


def sticker_logo(logo: Logo) -> str:
    """9 cm wide, black with rounded corners."""
    width, margin = 90, 5
    logo_width = width - 2 * margin
    height = logo_width * logo.aspect + 2 * margin
    body = f'<rect width="{width}" height="{height:g}" rx="4" fill="{BLACK}"/>'
    return svg(width, height, body + logo.place(logo.chrome("sticker"), margin, margin, logo_width))


def web_logo(logo: Logo) -> str:
    """Scalable, without physical size, for the dashboard header."""
    width = 1000
    height = width * logo.aspect
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height:g}">'
        f'{logo.place(logo.chrome("web"), 0, 0, width)}</svg>\n'
    )


def favicon() -> str:
    """"D⁶⁴" on a dark rounded square: the whole logo is too wide for an icon."""
    icon = Logo("D", LOGO_SUP)
    size, margin = 64, 6
    width = size - 2 * margin
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}">'
        f'<rect width="{size}" height="{size}" rx="12" fill="#11141a"/>'
        f'{icon.place(icon.chrome("icon"), margin, (size - width * icon.aspect) / 2, width)}</svg>\n'
    )


def main() -> None:
    logo = Logo()
    (HERE.parent / "web" / "logo.svg").write_text(web_logo(logo))
    (HERE.parent / "web" / "favicon.svg").write_text(favicon())
    print("wrote ../web/logo.svg and ../web/favicon.svg")
    files = {
        **tshirt_flex(logo),
        "tshirt-dtf": tshirt_dtf(logo),
        "sticker-cabinet": sticker_cabinet(logo),
        "sticker-logo": sticker_logo(logo),
    }
    OUT.mkdir(exist_ok=True)
    for name, content in files.items():
        (OUT / f"{name}.svg").write_text(content)
        print(f"wrote out/{name}.svg")


if __name__ == "__main__":
    main()
