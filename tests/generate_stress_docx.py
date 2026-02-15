#!/usr/bin/env python3
"""Generate a stress-test DOCX with images, footnotes, TOC, and mixed fonts.

Creates tests/fixtures/stress_test.docx — a highly complex document:
  - 10+ pages
  - 2+ embedded images (generated programmatically)
  - Footnotes
  - Table of contents
  - Different font on every line
  - Tables, page breaks, headers, colors, sizes
"""

import os
import struct
import zipfile
import zlib
import xml.sax.saxutils as saxutils

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------
W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
WP = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
A = "http://schemas.openxmlformats.org/drawingml/2006/main"
PIC = "http://schemas.openxmlformats.org/drawingml/2006/picture"
RELS_NS = "http://schemas.openxmlformats.org/package/2006/relationships"

ALL_NS = (
    f'xmlns:w="{W}" '
    f'xmlns:r="{R}" '
    f'xmlns:wp="{WP}" '
    f'xmlns:a="{A}" '
    f'xmlns:pic="{PIC}"'
)

# ---------------------------------------------------------------------------
# PNG generation (no PIL dependency)
# ---------------------------------------------------------------------------

def _png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    c = chunk_type + data
    crc = struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    return struct.pack(">I", len(data)) + c + crc


def make_png(width: int, height: int, pixel_func) -> bytes:
    """Create a PNG image. pixel_func(x, y) -> (r, g, b)."""
    raw = b""
    for y in range(height):
        raw += b"\x00"  # filter: None
        for x in range(width):
            r, g, b = pixel_func(x, y)
            raw += bytes([r, g, b])
    compressed = zlib.compress(raw)

    png = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png += _png_chunk(b"IHDR", ihdr)
    png += _png_chunk(b"IDAT", compressed)
    png += _png_chunk(b"IEND", b"")
    return png


def gradient_image(w=400, h=120):
    """Blue-to-orange horizontal gradient."""
    def pixel(x, y):
        t = x / max(w - 1, 1)
        r = int(30 + 225 * t)
        g = int(80 + 100 * (1 - t))
        b = int(220 * (1 - t))
        return (r, g, b)
    return make_png(w, h, pixel)


def checkerboard_image(w=400, h=200):
    """Colorful checkerboard pattern."""
    colors = [
        (220, 50, 50), (50, 160, 50), (50, 50, 200),
        (200, 180, 30), (180, 50, 180), (50, 180, 180),
    ]
    sq = 25
    def pixel(x, y):
        cx, cy = x // sq, y // sq
        idx = (cx + cy) % len(colors)
        return colors[idx]
    return make_png(w, h, pixel)


def chart_image(w=400, h=200):
    """Fake bar chart image."""
    bars = [0.7, 0.45, 0.9, 0.3, 0.6, 0.85, 0.5, 0.75]
    bar_colors = [
        (41, 128, 185), (39, 174, 96), (231, 76, 60), (243, 156, 18),
        (142, 68, 173), (52, 73, 94), (230, 126, 34), (46, 204, 113),
    ]
    bar_w = w // len(bars)
    def pixel(x, y):
        bi = min(x // bar_w, len(bars) - 1)
        bar_h = int(bars[bi] * (h - 20))
        bar_top = h - 20 - bar_h
        if y >= h - 20:
            return (60, 60, 60)  # axis
        if y >= bar_top and x % bar_w < bar_w - 4:
            return bar_colors[bi]
        return (245, 245, 245)  # background
    return make_png(w, h, pixel)


# ---------------------------------------------------------------------------
# XML helpers
# ---------------------------------------------------------------------------

def esc(text):
    return saxutils.escape(text)


def make_run(text, font=None, size=None, bold=False, italic=False,
             underline=False, strike=False, color=None, highlight=None,
             superscript=False, smallcaps=False):
    rpr = []
    if font:
        rpr.append(f'<w:rFonts w:ascii="{esc(font)}" w:hAnsi="{esc(font)}" w:cs="{esc(font)}"/>')
    if bold:
        rpr.append("<w:b/>")
    if italic:
        rpr.append("<w:i/>")
    if underline:
        rpr.append('<w:u w:val="single"/>')
    if strike:
        rpr.append("<w:strike/>")
    if smallcaps:
        rpr.append("<w:smallCaps/>")
    if superscript:
        rpr.append('<w:vertAlign w:val="superscript"/>')
    if size:
        hp = size * 2
        rpr.append(f'<w:sz w:val="{hp}"/><w:szCs w:val="{hp}"/>')
    if color:
        rpr.append(f'<w:color w:val="{color}"/>')
    if highlight:
        rpr.append(f'<w:highlight w:val="{highlight}"/>')

    rpr_xml = f"<w:rPr>{''.join(rpr)}</w:rPr>" if rpr else ""
    return f'<w:r>{rpr_xml}<w:t xml:space="preserve">{esc(text)}</w:t></w:r>'


def make_para(runs, align=None, style=None, spacing_after=None,
              indent_left=None, page_break_before=False,
              num_id=None, ilvl=None, borders=False):
    if isinstance(runs, str):
        runs = [runs]
    ppr = []
    if style:
        ppr.append(f'<w:pStyle w:val="{style}"/>')
    if page_break_before:
        ppr.append("<w:pageBreakBefore/>")
    if align:
        ppr.append(f'<w:jc w:val="{align}"/>')
    if indent_left:
        ppr.append(f'<w:ind w:left="{indent_left}"/>')
    if num_id is not None and ilvl is not None:
        ppr.append(f'<w:numPr><w:ilvl w:val="{ilvl}"/><w:numId w:val="{num_id}"/></w:numPr>')
    if spacing_after is not None:
        ppr.append(f'<w:spacing w:after="{spacing_after}"/>')
    if borders:
        ppr.append(
            '<w:pBdr>'
            '<w:top w:val="single" w:sz="4" w:space="1" w:color="999999"/>'
            '<w:bottom w:val="single" w:sz="4" w:space="1" w:color="999999"/>'
            '</w:pBdr>'
        )

    ppr_xml = f"<w:pPr>{''.join(ppr)}</w:pPr>" if ppr else ""
    return f"<w:p>{ppr_xml}{''.join(runs)}</w:p>"


def make_footnote_ref(fn_id):
    """Insert a footnote reference in the document body."""
    return (
        '<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr>'
        f'<w:footnoteReference w:id="{fn_id}"/></w:r>'
    )


def make_image_drawing(rel_id, cx_emu, cy_emu, name="image", desc="Image"):
    """Inline image drawing element (EMU units: 1 inch = 914400 EMU)."""
    return (
        f'<w:drawing>'
        f'<wp:inline distT="0" distB="0" distL="0" distR="0">'
        f'<wp:extent cx="{cx_emu}" cy="{cy_emu}"/>'
        f'<wp:docPr id="1" name="{esc(name)}" descr="{esc(desc)}"/>'
        f'<a:graphic xmlns:a="{A}">'
        f'<a:graphicData uri="{PIC}">'
        f'<pic:pic xmlns:pic="{PIC}">'
        f'<pic:nvPicPr><pic:cNvPr id="0" name="{esc(name)}"/><pic:cNvPicPr/></pic:nvPicPr>'
        f'<pic:blipFill><a:blip r:embed="{rel_id}"/>'
        f'<a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        f'<pic:spPr><a:xfrm><a:off x="0" y="0"/>'
        f'<a:ext cx="{cx_emu}" cy="{cy_emu}"/></a:xfrm>'
        f'<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
        f'</pic:pic>'
        f'</a:graphicData>'
        f'</a:graphic>'
        f'</wp:inline>'
        f'</w:drawing>'
    )


def make_table(rows_data, col_widths_twips=None):
    """Simple table. rows_data = [[cell_text, ...], ...]."""
    ncols = len(rows_data[0]) if rows_data else 0
    if not col_widths_twips:
        col_widths_twips = [9000 // ncols] * ncols

    grid = "".join(f'<w:gridCol w:w="{w}"/>' for w in col_widths_twips)
    tbl = (
        '<w:tbl>'
        '<w:tblPr>'
        '<w:tblStyle w:val="TableGrid"/>'
        '<w:tblW w:w="0" w:type="auto"/>'
        '<w:tblBorders>'
        '<w:top w:val="single" w:sz="4" w:space="0" w:color="333333"/>'
        '<w:left w:val="single" w:sz="4" w:space="0" w:color="333333"/>'
        '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="333333"/>'
        '<w:right w:val="single" w:sz="4" w:space="0" w:color="333333"/>'
        '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="333333"/>'
        '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="333333"/>'
        '</w:tblBorders>'
        '</w:tblPr>'
        f'<w:tblGrid>{grid}</w:tblGrid>'
    )

    for ri, row in enumerate(rows_data):
        tbl += "<w:tr>"
        for ci, cell in enumerate(row):
            shading = ""
            if ri == 0:
                shading = '<w:shd w:val="clear" w:color="auto" w:fill="2C3E50"/>'
            elif ri % 2 == 0:
                shading = '<w:shd w:val="clear" w:color="auto" w:fill="ECF0F1"/>'

            is_header = ri == 0
            cell_run = make_run(
                str(cell),
                font="Arial" if is_header else "Calibri",
                size=10 if is_header else 9,
                bold=is_header,
                color="FFFFFF" if is_header else "333333",
            )
            tbl += (
                f'<w:tc>'
                f'<w:tcPr><w:tcW w:w="{col_widths_twips[ci]}" w:type="dxa"/>{shading}</w:tcPr>'
                f'<w:p><w:pPr><w:spacing w:after="40"/></w:pPr>{cell_run}</w:p>'
                f'</w:tc>'
            )
        tbl += "</w:tr>"

    tbl += "</w:tbl>"
    return tbl


# ---------------------------------------------------------------------------
# TOC field
# ---------------------------------------------------------------------------

def make_toc():
    """Table of Contents via field codes (LO will compute page numbers)."""
    return (
        '<w:sdt>'
        '<w:sdtPr><w:docPartObj><w:docPartGallery w:val="Table of Contents"/>'
        '<w:docPartUnique/></w:docPartObj></w:sdtPr>'
        '<w:sdtContent>'
        + make_para(make_run("Table of Contents", font="Arial", size=26, bold=True, color="2C3E50"),
                    spacing_after="200")
        + '<w:p><w:pPr><w:spacing w:after="100"/></w:pPr>'
        '<w:r><w:rPr><w:b/></w:rPr>'
        '<w:fldChar w:fldCharType="begin"/></w:r>'
        '<w:r><w:instrText xml:space="preserve"> TOC \\o "1-3" \\h \\z \\u </w:instrText></w:r>'
        '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
        '<w:r><w:t>[Table of Contents — update to populate]</w:t></w:r>'
        '<w:r><w:fldChar w:fldCharType="end"/></w:r>'
        '</w:p>'
        + make_para([], spacing_after="400")
        + '</w:sdtContent></w:sdt>'
    )


# ---------------------------------------------------------------------------
# Document content
# ---------------------------------------------------------------------------

FONTS = [
    "Arial", "Times New Roman", "Courier New", "Georgia", "Verdana",
    "Trebuchet MS", "Palatino Linotype", "Book Antiqua", "Garamond",
    "Cambria", "Calibri", "Consolas", "Lucida Console", "Tahoma",
    "Century Gothic", "Franklin Gothic Medium", "Segoe UI",
    "Impact", "Arial Narrow", "Candara",
]

LOREM = [
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
    "Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.",
    "Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.",
    "Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.",
    "Curabitur pretium tincidunt lacus. Nulla gravida orci a odio. Nullam varius, turpis et commodo pharetra.",
    "Integer in mauris eu nibh euismod gravida. Duis ac tellus et risus vulputate vehicula.",
    "Pellentesque habitant morbi tristique senectus et netus et malesuada fames ac turpis egestas.",
    "Praesent dapibus, neque id cursus faucibus, tortor neque egestas augue, eu vulputate magna eros eu erat.",
]

COLORS = ["000000", "C0392B", "2980B9", "27AE60", "8E44AD", "D35400", "2C3E50", "16A085"]

FOOTNOTES_TEXT = [
    "This is an important clarification that provides additional context for the reader.",
    "See also: RFC 2119 for definitions of key terminology used throughout this document.",
    "Statistical significance was determined at the p < 0.05 level using a two-tailed test.",
    "The original source material was published in the Journal of Complex Systems, Vol. 42.",
    "Note that these values are approximations and may vary depending on environmental conditions.",
    "For a comprehensive treatment of this topic, consult Knuth, The Art of Computer Programming.",
    "This methodology was first described by Dijkstra in his seminal 1968 paper.",
    "Translation from the original Latin by the author; any errors are the author's own.",
]


def build_document():
    paras = []
    footnotes = []
    fn_id = 1  # footnote IDs start at 1 (0 and 1 are reserved for separator/continuation)

    # ---- Title page ----
    paras.append(make_para([], spacing_after="2000"))
    paras.append(make_para(
        make_run("COMPREHENSIVE STRESS TEST", font="Arial", size=36, bold=True, color="2C3E50"),
        align="center", spacing_after="200",
    ))
    paras.append(make_para(
        make_run("Document Conversion Validation Report", font="Georgia", size=20, italic=True, color="7F8C8D"),
        align="center", spacing_after="400",
    ))
    paras.append(make_para(
        make_run("Version 3.1 — February 2026", font="Calibri", size=12, color="95A5A6"),
        align="center", spacing_after="100",
    ))
    paras.append(make_para(
        make_run("Prepared by the SlimLO Quality Assurance Team", font="Calibri", size=11, color="BDC3C7"),
        align="center", spacing_after="200",
    ))
    paras.append(make_para(
        [make_run("CONFIDENTIAL", font="Arial", size=14, bold=True, color="E74C3C", smallcaps=True)],
        align="center", borders=True, spacing_after="100",
    ))

    # ---- Page break + TOC ----
    paras.append(make_para([], page_break_before=True))
    paras.append(make_toc())

    # ---- Chapter 1: Introduction with footnotes ----
    paras.append(make_para([], page_break_before=True))
    paras.append(make_para(
        make_run("1. Introduction", font="Arial", size=28, bold=True, color="2C3E50"),
        style="Heading1", spacing_after="200",
    ))

    intro_fonts = ["Georgia", "Palatino Linotype", "Cambria", "Book Antiqua", "Garamond"]
    intro_texts = [
        "This document serves as a comprehensive stress test for OOXML-to-PDF conversion engines.",
        "It exercises a wide range of DOCX features including embedded images, footnotes, tables of contents, and extensive font variation.",
        "Each line in this document intentionally uses a different typeface to verify that the conversion engine correctly handles font switching and fallback behavior.",
        "The document spans multiple pages to test pagination, header/footer handling, and memory management under sustained load.",
        "All images are procedurally generated and embedded directly in the OOXML archive, ensuring the test is fully self-contained without external dependencies.",
    ]
    for i, (text, font) in enumerate(zip(intro_texts, intro_fonts)):
        runs = [make_run(text, font=font, size=12)]
        # Add footnotes to some paragraphs
        if i in (0, 2, 4):
            fn_text = FOOTNOTES_TEXT[fn_id - 1] if fn_id <= len(FOOTNOTES_TEXT) else "Additional note."
            footnotes.append((fn_id + 1, fn_text, font))  # +1 because 0,1 are reserved
            runs.append(make_footnote_ref(fn_id + 1))
            fn_id += 1
        paras.append(make_para(runs, spacing_after="160"))

    # ---- Chapter 2: Image Gallery ----
    paras.append(make_para([], page_break_before=True))
    paras.append(make_para(
        make_run("2. Embedded Images", font="Arial", size=28, bold=True, color="2C3E50"),
        style="Heading1", spacing_after="200",
    ))

    paras.append(make_para(
        make_run("2.1 Gradient Image", font="Trebuchet MS", size=18, bold=True, color="2980B9"),
        style="Heading2", spacing_after="120",
    ))
    paras.append(make_para(
        make_run("The following image is a procedurally generated blue-to-orange gradient, embedded as a PNG:", font="Verdana", size=11),
        spacing_after="120",
    ))
    # Image 1: gradient (400x120px → ~5.3" x 1.6" at 96 DPI)
    img1_run = f'<w:r>{make_image_drawing("rId10", 4800000, 1440000, "gradient", "Gradient image")}</w:r>'
    paras.append(make_para(img1_run, align="center", spacing_after="200"))

    paras.append(make_para(
        make_run("Figure 1: Horizontal gradient from blue to orange", font="Calibri", size=9, italic=True, color="7F8C8D"),
        align="center", spacing_after="300",
    ))

    paras.append(make_para(
        make_run("2.2 Checkerboard Pattern", font="Trebuchet MS", size=18, bold=True, color="2980B9"),
        style="Heading2", spacing_after="120",
    ))
    paras.append(make_para(
        make_run("This checkerboard tests color accuracy and sharp edge rendering:", font="Tahoma", size=11),
        spacing_after="120",
    ))
    # Image 2: checkerboard (400x200px → ~5.3" x 2.6")
    img2_run = f'<w:r>{make_image_drawing("rId11", 4800000, 2400000, "checkerboard", "Checkerboard pattern")}</w:r>'
    paras.append(make_para(img2_run, align="center", spacing_after="200"))

    paras.append(make_para(
        make_run("Figure 2: Multi-colored checkerboard pattern with 25px squares", font="Calibri", size=9, italic=True, color="7F8C8D"),
        align="center", spacing_after="300",
    ))

    paras.append(make_para(
        make_run("2.3 Bar Chart", font="Trebuchet MS", size=18, bold=True, color="2980B9"),
        style="Heading2", spacing_after="120",
    ))
    paras.append(make_para(
        make_run("A simulated bar chart to test rendering of chart-like imagery:", font="Century Gothic", size=11),
        spacing_after="120",
    ))
    # Image 3: bar chart
    img3_run = f'<w:r>{make_image_drawing("rId12", 4800000, 2400000, "chart", "Bar chart")}</w:r>'
    paras.append(make_para(img3_run, align="center", spacing_after="200"))
    paras.append(make_para(
        make_run("Figure 3: Simulated bar chart with varying heights", font="Calibri", size=9, italic=True, color="7F8C8D"),
        align="center", spacing_after="300",
    ))

    # ---- Chapter 3: Font showcase (each line different font) ----
    paras.append(make_para([], page_break_before=True))
    paras.append(make_para(
        make_run("3. Font Showcase", font="Arial", size=28, bold=True, color="2C3E50"),
        style="Heading1", spacing_after="200",
    ))
    paras.append(make_para(
        make_run("Each line below uses a distinct typeface. This tests the engine's ability to load, render, and switch between fonts rapidly.",
                 font="Calibri", size=11, color="555555"),
        spacing_after="200",
    ))

    for i, font in enumerate(FONTS):
        color = COLORS[i % len(COLORS)]
        text = f"[{font}] The quick brown fox jumps over the lazy dog — 0123456789 !@#$%"
        runs = [make_run(text, font=font, size=11, color=color)]
        if i % 5 == 0 and fn_id <= len(FOOTNOTES_TEXT):
            fn_text = FOOTNOTES_TEXT[fn_id - 1] if fn_id <= len(FOOTNOTES_TEXT) else "Note."
            footnotes.append((fn_id + 1, fn_text, font))
            runs.append(make_footnote_ref(fn_id + 1))
            fn_id += 1
        paras.append(make_para(runs, spacing_after="100"))

    # ---- Chapter 4: Data Tables ----
    paras.append(make_para([], page_break_before=True))
    paras.append(make_para(
        make_run("4. Data Tables", font="Arial", size=28, bold=True, color="2C3E50"),
        style="Heading1", spacing_after="200",
    ))

    paras.append(make_para(
        make_run("4.1 Build Performance Matrix", font="Trebuchet MS", size=18, bold=True, color="2980B9"),
        style="Heading2", spacing_after="160",
    ))

    table1 = [
        ["Platform", "Architecture", "Build Time", "Artifact Size", "Libs", "Status"],
        ["Linux", "x64", "48 min", "186 MB", "134", "PASS"],
        ["Linux", "arm64", "3.2 hrs", "182 MB", "134", "PASS"],
        ["macOS", "arm64", "2.1 hrs", "108 MB", "140", "PASS"],
        ["macOS", "x64", "2.8 hrs", "146 MB", "140", "PASS"],
        ["Windows", "x64", "6+ hrs", "~200 MB", "TBD", "WIP"],
        ["Windows", "arm64", "TBD", "TBD", "TBD", "PLANNED"],
    ]
    paras.append(make_table(table1, [1800, 1500, 1200, 1500, 1000, 1000]))
    paras.append(make_para([], spacing_after="300"))

    paras.append(make_para(
        make_run("4.2 Font Coverage Test Results", font="Trebuchet MS", size=18, bold=True, color="2980B9"),
        style="Heading2", spacing_after="160",
    ))
    table2 = [
        ["Font Family", "Available", "Fallback", "Warnings", "Rendering"],
        ["Arial", "Yes", "—", "0", "Perfect"],
        ["Times New Roman", "Yes", "—", "0", "Perfect"],
        ["Courier New", "Yes", "—", "0", "Perfect"],
        ["Georgia", "Yes", "—", "0", "Perfect"],
        ["Verdana", "Yes", "—", "0", "Perfect"],
        ["Comic Sans MS", "Partial", "Arial", "1", "Acceptable"],
        ["Impact", "Partial", "Arial Black", "1", "Acceptable"],
        ["SuperRareFont", "No", "Liberation Sans", "3", "Degraded"],
        ["MyBrandFont", "No", "DejaVu Sans", "3", "Degraded"],
    ]
    paras.append(make_table(table2, [2200, 1200, 1800, 1200, 1600]))
    paras.append(make_para([], spacing_after="300"))

    # ---- Chapter 5: Mixed formatting stress ----
    paras.append(make_para([], page_break_before=True))
    paras.append(make_para(
        make_run("5. Mixed Formatting Stress Test", font="Arial", size=28, bold=True, color="2C3E50"),
        style="Heading1", spacing_after="200",
    ))

    # Paragraphs mixing bold/italic/underline/strike/color/size/font
    combos = [
        {"font": "Arial", "size": 14, "bold": True, "color": "C0392B"},
        {"font": "Georgia", "size": 11, "italic": True, "color": "2980B9"},
        {"font": "Courier New", "size": 10, "underline": True, "color": "27AE60"},
        {"font": "Verdana", "size": 13, "bold": True, "italic": True, "color": "8E44AD"},
        {"font": "Trebuchet MS", "size": 12, "strike": True, "color": "D35400"},
        {"font": "Calibri", "size": 11, "smallcaps": True, "color": "2C3E50"},
        {"font": "Palatino Linotype", "size": 15, "bold": True, "underline": True, "color": "16A085"},
        {"font": "Cambria", "size": 10, "italic": True, "underline": True, "color": "E74C3C"},
    ]

    for i in range(3):  # 3 rounds
        for j, combo in enumerate(combos):
            text = LOREM[(i * len(combos) + j) % len(LOREM)]
            label = f"[{combo['font']}, {combo.get('size',12)}pt"
            if combo.get('bold'): label += ", bold"
            if combo.get('italic'): label += ", italic"
            if combo.get('underline'): label += ", underline"
            if combo.get('strike'): label += ", strike"
            if combo.get('smallcaps'): label += ", smallcaps"
            label += "] "

            runs = [
                make_run(label, font="Consolas", size=8, color="999999"),
                make_run(text, **combo),
            ]
            if i == 0 and j % 3 == 0 and fn_id <= len(FOOTNOTES_TEXT):
                footnotes.append((fn_id + 1, FOOTNOTES_TEXT[fn_id - 1], combo["font"]))
                runs.append(make_footnote_ref(fn_id + 1))
                fn_id += 1
            paras.append(make_para(runs, spacing_after="120"))

    # ---- Chapter 6: Unicode & International ----
    paras.append(make_para([], page_break_before=True))
    paras.append(make_para(
        make_run("6. Unicode & International Text", font="Arial", size=28, bold=True, color="2C3E50"),
        style="Heading1", spacing_after="200",
    ))

    intl = [
        ("English — Arial", "Arial",
         "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs."),
        ("Français — Georgia", "Georgia",
         "Le vif renard brun saute par-dessus le chien paresseux. Portez ce vieux whisky au juge blond qui fume."),
        ("Deutsch — Cambria", "Cambria",
         "Franz jagt im komplett verwahrlosten Taxi quer durch Bayern. Zwölf Boxkämpfer jagen Eva quer über den großen Sylter Deich."),
        ("Español — Palatino", "Palatino Linotype",
         "El veloz murciélago hindú comía feliz cardillo y kiwi. La cigüeña tocaba el saxofón detrás del palenque de paja."),
        ("Italiano — Garamond", "Garamond",
         "Quel vituperabile xenofobo zelante difende il whisky. Ma la volpe col suo balzo ha raggiunto il quieto Fido."),
        ("Português — Calibri", "Calibri",
         "À noite, vovô Kowalsky vê o ímã cair no pé do pinguim queixoso e vomita."),
        ("Русский — Tahoma", "Tahoma",
         "Съешь ещё этих мягких французских булок, да выпей чаю. Широкая электрификация южных губерний даст мощный толчок подъёму сельского хозяйства."),
        ("日本語 — Segoe UI", "Segoe UI",
         "いろはにほへと ちりぬるを わかよたれそ つねならむ うゐのおくやま けふこえて あさきゆめみし ゑひもせす"),
        ("العربية — Arial", "Arial",
         "صِف خَلقَ خَودٍ كَمِثلِ الشَمسِ إِذ بَزَغَت — يَحظى الضَجيعُ بِها نَجلاءَ مِعطارِ"),
        ("Ελληνικά — Times New Roman", "Times New Roman",
         "Ξεσκεπάζω τὴν ψυχοφθόρα βδελυγμία — φθαρτὸν ἄωρον σῶμα ζωῆς ἀνθρωπίνης"),
    ]

    for label, font, text in intl:
        paras.append(make_para(
            make_run(label, font=font, size=11, bold=True, color="2C3E50"),
            spacing_after="40",
        ))
        paras.append(make_para(
            make_run(text, font=font, size=11),
            spacing_after="200",
        ))

    # ---- Chapter 7: Numbered & bulleted lists ----
    paras.append(make_para([], page_break_before=True))
    paras.append(make_para(
        make_run("7. Lists and Enumeration", font="Arial", size=28, bold=True, color="2C3E50"),
        style="Heading1", spacing_after="200",
    ))
    paras.append(make_para(
        make_run("7.1 Bulleted List", font="Trebuchet MS", size=18, bold=True, color="2980B9"),
        style="Heading2", spacing_after="120",
    ))
    bullets = [
        ("Arial", "Cross-platform build system with idempotent patch scripts"),
        ("Georgia", "Process-isolated worker architecture for crash resilience"),
        ("Verdana", "Length-prefixed JSON IPC protocol for .NET integration"),
        ("Calibri", "Automatic font diagnostics via stderr capture and parsing"),
        ("Trebuchet MS", "LTO optimization reducing merged library to ~65 MB"),
        ("Courier New", "ICU data filtering for en-US-only locale support"),
    ]
    for font, text in bullets:
        paras.append(make_para(
            make_run(f"\u2022 {text}", font=font, size=11),
            indent_left="720", spacing_after="60",
        ))

    paras.append(make_para(
        make_run("7.2 Numbered List", font="Trebuchet MS", size=18, bold=True, color="2980B9"),
        style="Heading2", spacing_after="120",
    ))
    numbered = [
        ("Palatino Linotype", "Clone vanilla LibreOffice source from upstream"),
        ("Cambria", "Apply SlimLO patch scripts (idempotent, order-dependent)"),
        ("Garamond", "Configure with --enable-slimlo and platform-specific flags"),
        ("Tahoma", "Build with make -jN (adjust N for available RAM)"),
        ("Segoe UI", "Extract minimal artifacts with extract-artifacts.sh"),
        ("Candara", "Build C API wrapper (libslimlo + slimlo_worker)"),
        ("Franklin Gothic Medium", "Package into NuGet native asset packages"),
        ("Century Gothic", "Run integration tests to validate DOCX→PDF conversion"),
    ]
    for i, (font, text) in enumerate(numbered, 1):
        paras.append(make_para(
            make_run(f"{i}. {text}", font=font, size=11),
            indent_left="720", spacing_after="60",
        ))

    # ---- Chapter 8: Color spectrum ----
    paras.append(make_para([], page_break_before=True))
    paras.append(make_para(
        make_run("8. Color Spectrum", font="Arial", size=28, bold=True, color="2C3E50"),
        style="Heading1", spacing_after="200",
    ))

    spectrum = [
        ("E74C3C", "Alizarin Red"), ("E67E22", "Carrot Orange"), ("F1C40F", "Sunflower Yellow"),
        ("2ECC71", "Emerald Green"), ("1ABC9C", "Turquoise"), ("3498DB", "Peter River Blue"),
        ("9B59B6", "Amethyst Purple"), ("34495E", "Wet Asphalt"), ("95A5A6", "Concrete Gray"),
        ("E84393", "Fuchsia Pink"), ("6C5CE7", "Lavender"), ("00CEC9", "Cyan"),
        ("FDCB6E", "Gold"), ("E17055", "Burnt Sienna"), ("0984E3", "Electron Blue"),
        ("636E72", "Smoke Gray"), ("2D3436", "Graphite"), ("D63031", "Pomegranate"),
    ]
    for i, (color, name) in enumerate(spectrum):
        font = FONTS[i % len(FONTS)]
        paras.append(make_para(
            [
                make_run(f"\u2588\u2588\u2588 ", font="Consolas", size=14, color=color),
                make_run(f"{name} (#{color}) — ", font=font, size=11, bold=True, color=color),
                make_run(f"Rendered in {font}", font=font, size=11, color="555555"),
            ],
            spacing_after="80",
        ))

    # ---- Appendix: Size variations ----
    paras.append(make_para([], page_break_before=True))
    paras.append(make_para(
        make_run("Appendix A: Font Size Ladder", font="Arial", size=28, bold=True, color="2C3E50"),
        style="Heading1", spacing_after="200",
    ))

    for pt in [6, 7, 8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 36, 48]:
        font = FONTS[pt % len(FONTS)]
        paras.append(make_para(
            make_run(f"{pt}pt — {font}: The quick brown fox", font=font, size=pt),
            spacing_after="60",
        ))

    # ---- Final page ----
    paras.append(make_para([], page_break_before=True))
    paras.append(make_para([], spacing_after="2000"))
    paras.append(make_para(
        make_run("— End of Document —", font="Georgia", size=18, italic=True, color="7F8C8D"),
        align="center", spacing_after="200",
    ))
    paras.append(make_para(
        make_run(f"This document contains {len(paras)} paragraphs, {len(footnotes)} footnotes, "
                 f"3 embedded images, 2 tables, and {len(FONTS)} distinct fonts.",
                 font="Calibri", size=9, color="BDC3C7"),
        align="center",
    ))

    return paras, footnotes


# ---------------------------------------------------------------------------
# OOXML assembly
# ---------------------------------------------------------------------------

def build_footnotes_xml(footnotes):
    """Build word/footnotes.xml."""
    parts = [
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        f'<w:footnotes xmlns:w="{W}" xmlns:r="{R}">',
        # Required separator and continuation separator (IDs 0 and 1)
        '<w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>',
        '<w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>',
    ]
    for fn_id, text, font in footnotes:
        parts.append(
            f'<w:footnote w:id="{fn_id}">'
            f'<w:p>'
            f'<w:pPr><w:pStyle w:val="FootnoteText"/></w:pPr>'
            f'<w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr>'
            f'<w:footnoteRef/></w:r>'
            f'<w:r><w:rPr>'
            f'<w:rFonts w:ascii="{esc(font)}" w:hAnsi="{esc(font)}"/>'
            f'<w:sz w:val="18"/><w:szCs w:val="18"/>'
            f'</w:rPr>'
            f'<w:t xml:space="preserve"> {esc(text)}</w:t></w:r>'
            f'</w:p>'
            f'</w:footnote>'
        )
    parts.append('</w:footnotes>')
    return "\n".join(parts)


def build_styles_xml():
    """Minimal styles for headings and footnotes."""
    return f"""\
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="{W}">
  <w:style w:type="paragraph" w:styleId="Heading1">
    <w:name w:val="heading 1"/>
    <w:pPr><w:keepNext/><w:outlineLvl w:val="0"/></w:pPr>
    <w:rPr><w:b/><w:sz w:val="48"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading2">
    <w:name w:val="heading 2"/>
    <w:pPr><w:keepNext/><w:outlineLvl w:val="1"/></w:pPr>
    <w:rPr><w:b/><w:sz w:val="36"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading3">
    <w:name w:val="heading 3"/>
    <w:pPr><w:keepNext/><w:outlineLvl w:val="2"/></w:pPr>
    <w:rPr><w:b/><w:sz w:val="28"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="FootnoteText">
    <w:name w:val="footnote text"/>
    <w:rPr><w:sz w:val="18"/></w:rPr>
  </w:style>
  <w:style w:type="character" w:styleId="FootnoteReference">
    <w:name w:val="footnote reference"/>
    <w:rPr><w:vertAlign w:val="superscript"/></w:rPr>
  </w:style>
</w:styles>"""


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    fixtures_dir = os.path.join(script_dir, "fixtures")
    os.makedirs(fixtures_dir, exist_ok=True)
    out_path = os.path.join(fixtures_dir, "stress_test.docx")

    print("Generating stress_test.docx ...")

    paras, footnotes = build_document()

    # Generate images
    print("  Generating images...")
    img_gradient = gradient_image()
    img_checker = checkerboard_image()
    img_chart = chart_image()

    # Build document.xml
    sect_pr = (
        '<w:sectPr>'
        '<w:pgSz w:w="12240" w:h="15840"/>'
        '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" '
        'w:header="720" w:footer="720" w:gutter="0"/>'
        '<w:footnotePr><w:numFmt w:val="decimal"/></w:footnotePr>'
        '</w:sectPr>'
    )

    body = "\n".join(paras) + "\n" + sect_pr
    doc_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        f'<w:document {ALL_NS}>\n'
        f'  <w:body>\n{body}\n  </w:body>\n'
        f'</w:document>'
    )

    # Content types
    content_types = f"""\
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Default Extension="png" ContentType="image/png"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
  <Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/>
</Types>"""

    # Relationships
    rels = f"""\
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="{RELS_NS}">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>"""

    doc_rels = f"""\
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="{RELS_NS}">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes" Target="footnotes.xml"/>
  <Relationship Id="rId10" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/gradient.png"/>
  <Relationship Id="rId11" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/checkerboard.png"/>
  <Relationship Id="rId12" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/chart.png"/>
</Relationships>"""

    # Write DOCX
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", content_types)
        zf.writestr("_rels/.rels", rels)
        zf.writestr("word/document.xml", doc_xml)
        zf.writestr("word/_rels/document.xml.rels", doc_rels)
        zf.writestr("word/styles.xml", build_styles_xml())
        zf.writestr("word/footnotes.xml", build_footnotes_xml(footnotes))
        zf.writestr("word/media/gradient.png", img_gradient)
        zf.writestr("word/media/checkerboard.png", img_checker)
        zf.writestr("word/media/chart.png", img_chart)

    size = os.path.getsize(out_path)
    print(f"  Created {out_path}")
    print(f"  Size: {size:,} bytes")
    print(f"  Paragraphs: {len(paras)}")
    print(f"  Footnotes: {len(footnotes)}")
    print(f"  Images: 3")
    print(f"  Fonts: {len(FONTS)}")
    print("Done.")


if __name__ == "__main__":
    main()
