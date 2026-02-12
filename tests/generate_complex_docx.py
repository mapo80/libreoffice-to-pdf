#!/usr/bin/env python3
"""Generate complex DOCX test files for SlimLO conversion testing.

Creates multiple test documents in tests/fixtures/ to exercise different
aspects of OOXML-to-PDF conversion: fonts, formatting, unicode, stress.

Each .docx is a ZIP archive with minimal OOXML structure:
  [Content_Types].xml
  _rels/.rels
  word/document.xml
  word/_rels/document.xml.rels
"""

import os
import zipfile
import xml.sax.saxutils as saxutils

# ---------------------------------------------------------------------------
# Shared OOXML boilerplate
# ---------------------------------------------------------------------------

CONTENT_TYPES = """\
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml"
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/numbering.xml"
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
</Types>"""

CONTENT_TYPES_NO_NUMBERING = """\
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml"
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>"""

RELS = """\
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1"
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    Target="word/document.xml"/>
</Relationships>"""

DOC_RELS = """\
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
</Relationships>"""

DOC_RELS_WITH_NUMBERING = """\
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1"
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering"
    Target="numbering.xml"/>
</Relationships>"""

SECT_PR = """\
    <w:sectPr>
      <w:pgSz w:w="12240" w:h="15840"/>
      <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"
               w:header="720" w:footer="720" w:gutter="0"/>
    </w:sectPr>"""

W_NS = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
R_NS = 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'

NUMBERING_XML = """\
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="0">
    <w:lvl w:ilvl="0">
      <w:start w:val="1"/>
      <w:numFmt w:val="decimal"/>
      <w:lvlText w:val="%1."/>
      <w:lvlJc w:val="left"/>
      <w:pPr>
        <w:ind w:left="720" w:hanging="360"/>
      </w:pPr>
    </w:lvl>
  </w:abstractNum>
  <w:num w:numId="1">
    <w:abstractNumId w:val="0"/>
  </w:num>
</w:numbering>"""


# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

def esc(text):
    """Escape text for XML content."""
    return saxutils.escape(text)


def make_run(text, font=None, size=None, bold=False, italic=False,
             underline=False, strike=False, color=None):
    """Build a <w:r> element with optional formatting."""
    rpr_parts = []
    if font:
        rpr_parts.append(
            f'<w:rFonts w:ascii="{esc(font)}" w:hAnsi="{esc(font)}" '
            f'w:cs="{esc(font)}"/>'
        )
    if bold:
        rpr_parts.append("<w:b/>")
    if italic:
        rpr_parts.append("<w:i/>")
    if underline:
        rpr_parts.append('<w:u w:val="single"/>')
    if strike:
        rpr_parts.append("<w:strike/>")
    if size:
        half_pts = size * 2
        rpr_parts.append(f'<w:sz w:val="{half_pts}"/>')
        rpr_parts.append(f'<w:szCs w:val="{half_pts}"/>')
    if color:
        rpr_parts.append(f'<w:color w:val="{color}"/>')

    rpr = ""
    if rpr_parts:
        rpr = "<w:rPr>" + "".join(rpr_parts) + "</w:rPr>"

    return (
        f"<w:r>{rpr}"
        f'<w:t xml:space="preserve">{esc(text)}</w:t>'
        f"</w:r>"
    )


def make_para(runs, align=None, style=None, indent_left=None,
              num_id=None, ilvl=None, spacing_after=None):
    """Build a <w:p> element from one or more runs (strings)."""
    ppr_parts = []
    if style:
        ppr_parts.append(f'<w:pStyle w:val="{style}"/>')
    if align:
        ppr_parts.append(f'<w:jc w:val="{align}"/>')
    if indent_left:
        ppr_parts.append(f'<w:ind w:left="{indent_left}"/>')
    if num_id is not None and ilvl is not None:
        ppr_parts.append(
            f"<w:numPr>"
            f'<w:ilvl w:val="{ilvl}"/>'
            f'<w:numId w:val="{num_id}"/>'
            f"</w:numPr>"
        )
    if spacing_after is not None:
        ppr_parts.append(f'<w:spacing w:after="{spacing_after}"/>')

    ppr = ""
    if ppr_parts:
        ppr = "<w:pPr>" + "".join(ppr_parts) + "</w:pPr>"

    if isinstance(runs, str):
        runs = [runs]

    return "<w:p>" + ppr + "".join(runs) + "</w:p>"


def wrap_document(body_xml):
    """Wrap body paragraphs in a complete document.xml."""
    return (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        f"<w:document {W_NS} {R_NS}>\n"
        f"  <w:body>\n{body_xml}\n{SECT_PR}\n  </w:body>\n"
        f"</w:document>"
    )


def write_docx(path, document_xml, include_numbering=False):
    """Write a .docx ZIP archive."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        if include_numbering:
            zf.writestr("[Content_Types].xml", CONTENT_TYPES)
            zf.writestr("word/_rels/document.xml.rels", DOC_RELS_WITH_NUMBERING)
            zf.writestr("word/numbering.xml", NUMBERING_XML)
        else:
            zf.writestr("[Content_Types].xml", CONTENT_TYPES_NO_NUMBERING)
            zf.writestr("word/_rels/document.xml.rels", DOC_RELS)
        zf.writestr("_rels/.rels", RELS)
        zf.writestr("word/document.xml", document_xml)
    size = os.path.getsize(path)
    print(f"  Created {os.path.basename(path)} ({size:,} bytes)")


# ---------------------------------------------------------------------------
# 1. multi_font.docx
# ---------------------------------------------------------------------------

def generate_multi_font():
    fonts = [
        ("Arial Black", "This heading uses Arial Black", True, 28),
        ("Times New Roman",
         "This paragraph uses Times New Roman, a classic serif font commonly "
         "used for body text in documents. It should render with serifs on "
         "each character.",
         False, 12),
        ("Courier New",
         "This paragraph uses Courier New (monospace). "
         "Each character occupies the same width: iiii WWWW.",
         False, 11),
        ("Georgia",
         "This paragraph uses Georgia, a serif font designed for screen "
         "readability. It has a warm, elegant appearance.",
         False, 12),
        ("Verdana",
         "This paragraph uses Verdana, a sans-serif font with wide "
         "letter-spacing designed for clarity at small sizes.",
         False, 12),
        ("Comic Sans MS",
         "This paragraph uses Comic Sans MS, a casual decorative font. "
         "Love it or hate it, it is useful for testing font coverage.",
         False, 12),
        ("Trebuchet MS",
         "This paragraph uses Trebuchet MS, a humanist sans-serif font. "
         "It has distinctive features like the slanted 'e'.",
         False, 12),
    ]

    paras = []
    paras.append(make_para(
        make_run("Multi-Font Test Document", font="Arial Black", size=28,
                 bold=True),
        align="center",
        spacing_after="400",
    ))
    paras.append(make_para(
        make_run(
            "This document tests rendering of multiple fonts. Each paragraph "
            "below identifies which font it uses.",
            size=10, color="666666",
        ),
        spacing_after="200",
    ))

    for font_name, text, bold, size in fonts:
        label = make_run(f"[Font: {font_name}] ", font=font_name, size=size,
                         bold=True, color="333399")
        content = make_run(text, font=font_name, size=size, bold=bold)
        paras.append(make_para([label, content], spacing_after="200"))

    return wrap_document("\n".join(paras))


# ---------------------------------------------------------------------------
# 2. missing_fonts.docx
# ---------------------------------------------------------------------------

def generate_missing_fonts():
    missing_fonts = [
        "SuperRareFont2024",
        "MyCustomBrandFont",
        "FancyDisplayPro",
        "UnicornTypeFace",
    ]

    paras = []
    paras.append(make_para(
        make_run("Missing Font Test Document", size=28, bold=True),
        align="center",
        spacing_after="400",
    ))
    paras.append(make_para(
        make_run(
            "This document uses fonts that do not exist on any standard "
            "system. The PDF converter should emit font warnings and fall "
            "back to a default font. The last paragraph uses Arial as a "
            "baseline that SHOULD render correctly.",
            size=10, color="666666",
        ),
        spacing_after="200",
    ))

    for font_name in missing_fonts:
        paras.append(make_para(
            [
                make_run(f"[Font: {font_name}] ", font=font_name, size=14,
                         bold=True, color="CC0000"),
                make_run(
                    f"This paragraph is set in \"{font_name}\". If you see "
                    f"this text rendered in a default/fallback font, the "
                    f"converter handled the missing font gracefully.",
                    font=font_name, size=12,
                ),
            ],
            spacing_after="200",
        ))

    # Baseline paragraph in Arial
    paras.append(make_para(
        [
            make_run("[Font: Arial - BASELINE] ", font="Arial", size=14,
                     bold=True, color="006600"),
            make_run(
                "This paragraph uses Arial, which should be available on all "
                "systems. It serves as a baseline to confirm that known fonts "
                "render correctly while the above missing fonts trigger "
                "fallback behavior.",
                font="Arial", size=12,
            ),
        ],
        spacing_after="200",
    ))

    return wrap_document("\n".join(paras))


# ---------------------------------------------------------------------------
# 3. rich_formatting.docx
# ---------------------------------------------------------------------------

def generate_rich_formatting():
    paras = []

    # Heading 1
    paras.append(make_para(
        make_run("Heading Level 1: Rich Formatting Test", size=28, bold=True),
        style="Heading1",
        spacing_after="200",
    ))

    # Heading 2
    paras.append(make_para(
        make_run("Heading Level 2: Text Styles", size=22, bold=True),
        style="Heading2",
        spacing_after="160",
    ))

    # Heading 3
    paras.append(make_para(
        make_run("Heading Level 3: Inline Formatting", size=18, bold=True),
        style="Heading3",
        spacing_after="120",
    ))

    # Bold, italic, underline, strikethrough
    paras.append(make_para([
        make_run("Bold text. ", bold=True, size=12),
        make_run("Italic text. ", italic=True, size=12),
        make_run("Underlined text. ", underline=True, size=12),
        make_run("Strikethrough text. ", strike=True, size=12),
        make_run("Bold italic underlined.", bold=True, italic=True,
                 underline=True, size=12),
    ], spacing_after="120"))

    # Font sizes
    paras.append(make_para(
        make_run("Font Size Variations:", size=12, bold=True),
        spacing_after="60",
    ))
    for pt in [8, 12, 18, 24, 36]:
        paras.append(make_para(
            make_run(f"This text is {pt}pt", size=pt),
            spacing_after="60",
        ))

    # Colors
    paras.append(make_para(
        make_run("Color Variations:", size=12, bold=True),
        spacing_after="60",
    ))
    colors = [
        ("FF0000", "Red"),
        ("0000FF", "Blue"),
        ("008000", "Green"),
        ("000000", "Black"),
        ("FF8C00", "Dark Orange"),
        ("800080", "Purple"),
    ]
    paras.append(make_para(
        [make_run(f"{name} ", size=14, color=code, bold=True)
         for code, name in colors],
        spacing_after="120",
    ))

    # Alignment
    paras.append(make_para(
        make_run("Heading Level 2: Alignment", size=22, bold=True),
        style="Heading2",
        spacing_after="160",
    ))
    paras.append(make_para(
        make_run("This paragraph is left-aligned (default).", size=12),
        align="left",
        spacing_after="60",
    ))
    paras.append(make_para(
        make_run("This paragraph is center-aligned.", size=12),
        align="center",
        spacing_after="60",
    ))
    paras.append(make_para(
        make_run("This paragraph is right-aligned.", size=12),
        align="right",
        spacing_after="60",
    ))

    # Bulleted list (using Unicode bullet + indent)
    paras.append(make_para(
        make_run("Heading Level 2: Lists", size=22, bold=True),
        style="Heading2",
        spacing_after="160",
    ))
    paras.append(make_para(
        make_run("Bulleted list:", size=12, bold=True),
        spacing_after="60",
    ))
    bullets = [
        "First bullet item",
        "Second bullet item with longer text to test wrapping behavior "
        "when the content extends beyond a single line",
        "Third bullet item",
        "Fourth bullet item",
    ]
    for item in bullets:
        paras.append(make_para(
            make_run(f"\u2022 {item}", size=12),
            indent_left="720",
            spacing_after="40",
        ))

    # Numbered list (using numbering.xml reference)
    paras.append(make_para(
        make_run("Numbered list:", size=12, bold=True),
        spacing_after="60",
    ))
    numbered_items = [
        "First numbered item",
        "Second numbered item",
        "Third numbered item with more text to demonstrate that numbered "
        "lists also handle line wrapping correctly",
        "Fourth numbered item",
    ]
    for item in numbered_items:
        paras.append(make_para(
            make_run(item, size=12),
            num_id=1, ilvl=0,
            spacing_after="40",
        ))

    # Combined formatting
    paras.append(make_para(
        make_run("Heading Level 2: Combined Formatting", size=22, bold=True),
        style="Heading2",
        spacing_after="160",
    ))
    paras.append(make_para([
        make_run("Large ", font="Georgia", size=24, bold=True, color="FF0000"),
        make_run("bold red Georgia", font="Georgia", size=24, bold=True,
                 color="FF0000"),
        make_run(" mixed with ", size=12),
        make_run("small blue italic Verdana", font="Verdana", size=9,
                 italic=True, color="0000FF"),
        make_run(" in a single paragraph.", size=12),
    ], spacing_after="120"))

    return wrap_document("\n".join(paras))


# ---------------------------------------------------------------------------
# 4. unicode_text.docx
# ---------------------------------------------------------------------------

def generate_unicode_text():
    paras = []

    paras.append(make_para(
        make_run("Unicode and International Text Test", size=28, bold=True),
        align="center",
        spacing_after="400",
    ))

    sections = [
        ("English", "The quick brown fox jumps over the lazy dog. "
         "Pack my box with five dozen liquor jugs."),
        ("Chinese (Simplified)", "\u4f60\u597d\u4e16\u754c\u3002"
         "\u8fd9\u662f\u4e00\u4e2a\u6d4b\u8bd5\u6587\u6863\uff0c"
         "\u7528\u4e8e\u9a8c\u8bc1\u4e2d\u6587\u5b57\u7b26\u7684"
         "\u6e32\u67d3\u3002"),
        ("Japanese",
         "\u3053\u3093\u306b\u3061\u306f\u4e16\u754c\u3002"
         "\u3053\u308c\u306f\u30c6\u30b9\u30c8\u6587\u66f8\u3067\u3059\u3002"
         "\u65e5\u672c\u8a9e\u306e\u30ec\u30f3\u30c0\u30ea\u30f3\u30b0"
         "\u3092\u78ba\u8a8d\u3057\u307e\u3059\u3002"),
        ("Korean",
         "\uc548\ub155\ud558\uc138\uc694 \uc138\uacc4. "
         "\uc774\uac83\uc740 \ud55c\uad6d\uc5b4 \ud14d\uc2a4\ud2b8 "
         "\ub80c\ub354\ub9c1\uc744 \ud14c\uc2a4\ud2b8\ud558\ub294 "
         "\ubb38\uc11c\uc785\ub2c8\ub2e4."),
        ("Arabic (RTL)",
         "\u0645\u0631\u062d\u0628\u0627 \u0628\u0627\u0644\u0639\u0627"
         "\u0644\u0645. \u0647\u0630\u0627 \u0645\u0633\u062a\u0646\u062f "
         "\u0627\u062e\u062a\u0628\u0627\u0631 \u0644\u0644\u063a\u0629 "
         "\u0627\u0644\u0639\u0631\u0628\u064a\u0629."),
        ("Cyrillic (Russian)",
         "\u041f\u0440\u0438\u0432\u0435\u0442 \u043c\u0438\u0440. "
         "\u042d\u0442\u043e \u0442\u0435\u0441\u0442\u043e\u0432\u044b\u0439"
         " \u0434\u043e\u043a\u0443\u043c\u0435\u043d\u0442 \u0434\u043b\u044f"
         " \u043f\u0440\u043e\u0432\u0435\u0440\u043a\u0438 "
         "\u043a\u0438\u0440\u0438\u043b\u043b\u0438\u0446\u044b."),
        ("Hebrew (RTL)",
         "\u05e9\u05dc\u05d5\u05dd \u05e2\u05d5\u05dc\u05dd. "
         "\u05d6\u05d4\u05d5 \u05de\u05e1\u05de\u05da "
         "\u05d1\u05d3\u05d9\u05e7\u05d4."),
        ("Thai",
         "\u0e2a\u0e27\u0e31\u0e2a\u0e14\u0e35\u0e0a\u0e32\u0e27"
         "\u0e42\u0e25\u0e01. "
         "\u0e19\u0e35\u0e48\u0e04\u0e37\u0e2d\u0e40\u0e2d\u0e01\u0e2a"
         "\u0e32\u0e23\u0e17\u0e14\u0e2a\u0e2d\u0e1a."),
    ]

    for label, text in sections:
        paras.append(make_para(
            make_run(f"[{label}]", size=11, bold=True, color="333399"),
            spacing_after="40",
        ))
        paras.append(make_para(
            make_run(text, size=12),
            spacing_after="200",
        ))

    # Symbols
    paras.append(make_para(
        make_run("[Common Symbols]", size=11, bold=True, color="333399"),
        spacing_after="40",
    ))
    paras.append(make_para(
        make_run(
            "\u2122 \u00a9 \u00ae \u20ac \u00a3 \u00a5 \u00a7 \u00b6 "
            "\u2020 \u2021 \u2022 \u2026 \u2014 \u2013",
            size=14,
        ),
        spacing_after="200",
    ))

    # Mathematical symbols
    paras.append(make_para(
        make_run("[Mathematical Symbols]", size=11, bold=True, color="333399"),
        spacing_after="40",
    ))
    paras.append(make_para(
        make_run(
            "\u2211 \u222b \u2202 \u221a \u221e \u2260 \u2264 \u2265 "
            "\u00b1 \u00d7 \u00f7 \u03b1 \u03b2 \u03b3 \u03b4 \u03c0 "
            "\u03a3 \u0394 \u03a9",
            size=14,
        ),
        spacing_after="200",
    ))

    # Emoji and misc
    paras.append(make_para(
        make_run("[Box Drawing and Misc]", size=11, bold=True, color="333399"),
        spacing_after="40",
    ))
    paras.append(make_para(
        make_run(
            "\u250c\u2500\u2500\u2500\u2510  \u2500\u2500\u2500  "
            "\u2502   \u2502  \u2190 \u2191 \u2192 \u2193 "
            "\u2514\u2500\u2500\u2500\u2518  \u2588\u2591\u2592\u2593",
            font="Courier New", size=12,
        ),
        spacing_after="200",
    ))

    return wrap_document("\n".join(paras))


# ---------------------------------------------------------------------------
# 5. large_document.docx
# ---------------------------------------------------------------------------

def generate_large_document():
    paras = []

    paras.append(make_para(
        make_run("Large Document Stress Test", size=32, bold=True),
        align="center",
        spacing_after="400",
    ))
    paras.append(make_para(
        make_run(
            "This document contains enough content to span at least 20 pages, "
            "mixing headings, body text, lists, and varied fonts to exercise "
            "the converter under load.",
            size=10, color="666666",
        ),
        spacing_after="200",
    ))

    fonts = [
        "Times New Roman", "Arial", "Courier New", "Georgia",
        "Verdana", "Trebuchet MS",
    ]

    lorem_paragraphs = [
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do "
        "eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim "
        "ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut "
        "aliquip ex ea commodo consequat. Duis aute irure dolor in "
        "reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla "
        "pariatur.",

        "Excepteur sint occaecat cupidatat non proident, sunt in culpa qui "
        "officia deserunt mollit anim id est laborum. Curabitur pretium "
        "tincidunt lacus. Nulla gravida orci a odio. Nullam varius, turpis "
        "et commodo pharetra, est eros bibendum elit, nec luctus magna felis "
        "sollicitudin mauris.",

        "Integer in mauris eu nibh euismod gravida. Duis ac tellus et risus "
        "vulputate vehicula. Donec lobortis risus a elit. Etiam tempor. Ut "
        "ullamcorper, ligula ut dictum pharetra, nisi nunc fringilla magna, "
        "in commodo elit erat nec turpis. Ut pharetra, leo id laoreet "
        "faucibus, massa felis volutpat odio, a elementum dui orci non arcu.",

        "Pellentesque habitant morbi tristique senectus et netus et malesuada "
        "fames ac turpis egestas. Vestibulum tortor quam, feugiat vitae, "
        "ultricies eget, tempor sit amet, ante. Donec eu libero sit amet "
        "quam egestas semper. Aenean ultricies mi vitae est. Mauris placerat "
        "eleifend leo.",

        "Quisque sit amet est et sapien ullamcorper pharetra. Vestibulum "
        "erat wisi, condimentum sed, commodo vitae, ornare sit amet, wisi. "
        "Aenean fermentum, elit eget tincidunt condimentum, eros ipsum "
        "rutrum orci, sagittis tempus lacus enim ac dui. Donec non enim in "
        "turpis pulvinar facilisis. Ut felis.",

        "Praesent dapibus, neque id cursus faucibus, tortor neque egestas "
        "augue, eu vulputate magna eros eu erat. Aliquam erat volutpat. Nam "
        "dui mi, tincidunt quis, accumsan porttitor, facilisis luctus, "
        "metus. Phasellus ultrices nulla quis nibh. Quisque a lectus.",
    ]

    # Generate ~25 chapters to ensure 20+ pages
    for chapter in range(1, 26):
        font = fonts[chapter % len(fonts)]

        # Chapter heading (H1)
        paras.append(make_para(
            make_run(f"Chapter {chapter}: Section with {font}",
                     size=24, bold=True, font=font),
            style="Heading1",
            spacing_after="200",
        ))

        # Subheading (H2)
        paras.append(make_para(
            make_run(f"Section {chapter}.1 -- Introduction",
                     size=18, bold=True, font=font),
            style="Heading2",
            spacing_after="120",
        ))

        # Body paragraphs
        for i in range(5):
            idx = (chapter + i) % len(lorem_paragraphs)
            paras.append(make_para(
                make_run(lorem_paragraphs[idx], size=11, font=font),
                spacing_after="120",
            ))

        # Subheading (H2)
        paras.append(make_para(
            make_run(f"Section {chapter}.2 -- Key Points",
                     size=18, bold=True, font=font),
            style="Heading2",
            spacing_after="120",
        ))

        # Bullet list
        items = [
            f"Point {chapter}.{j}: "
            + lorem_paragraphs[(chapter + j) % len(lorem_paragraphs)][:80]
            for j in range(1, 5)
        ]
        for item in items:
            paras.append(make_para(
                make_run(f"\u2022 {item}", size=11, font=font),
                indent_left="720",
                spacing_after="40",
            ))

        # Another body paragraph
        paras.append(make_para(
            make_run(
                lorem_paragraphs[(chapter * 2) % len(lorem_paragraphs)],
                size=11, font=font,
            ),
            spacing_after="200",
        ))

        # Subheading (H3)
        paras.append(make_para(
            make_run(f"Section {chapter}.3 -- Summary",
                     size=14, bold=True, italic=True, font=font),
            style="Heading3",
            spacing_after="80",
        ))

        paras.append(make_para(
            make_run(
                f"This concludes chapter {chapter}. The next chapter will "
                f"continue with additional content in a different font to "
                f"exercise font switching throughout the document.",
                size=11, font=font, italic=True, color="555555",
            ),
            spacing_after="300",
        ))

    # Final page
    paras.append(make_para(
        make_run("--- End of Document ---", size=16, bold=True),
        align="center",
        spacing_after="200",
    ))
    paras.append(make_para(
        make_run(
            f"This document contains {len(paras)} paragraphs across 25 "
            f"chapters with varied fonts, headings, lists, and formatting.",
            size=10, color="888888",
        ),
        align="center",
    ))

    return wrap_document("\n".join(paras))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    fixtures_dir = os.path.join(script_dir, "fixtures")
    os.makedirs(fixtures_dir, exist_ok=True)

    generators = [
        ("multi_font.docx", generate_multi_font, False),
        ("missing_fonts.docx", generate_missing_fonts, False),
        ("rich_formatting.docx", generate_rich_formatting, True),
        ("unicode_text.docx", generate_unicode_text, False),
        ("large_document.docx", generate_large_document, False),
    ]

    print(f"Generating test DOCX files in {fixtures_dir}/")
    for filename, gen_func, needs_numbering in generators:
        path = os.path.join(fixtures_dir, filename)
        doc_xml = gen_func()
        write_docx(path, doc_xml, include_numbering=needs_numbering)

    print("Done.")


if __name__ == "__main__":
    main()
