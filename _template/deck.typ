// Slide template for the training deck (16:9, 960pt x 540pt, one page per slide).
// Same palette and logos as panduan.typ.
//
//   #import "../_template/deck.typ": *
//   #show: deck.with(
//     title: "...", subtitle: "...", day-label: "HARI 1",
//     client: sys.inputs.at("client"), date: "26 Oktober 2026",
//   )
//   #section-slide(number: "01", title: "...")
//   #slide(kicker: "...", title: "...")[ ... ]

// ── Palette ────────────────────────────────────────────────────────────────
#let navy    = rgb("#2e3192")
#let navy-dk = rgb("#1f2266")
#let gold    = rgb("#58c034")
#let cream   = rgb("#f8f7fa")
#let slate   = rgb("#4b5563")
#let border  = rgb("#cbd5e1")
#let panel   = rgb("#eef0f9")
#let ink     = rgb("#1f2937")
#let faint   = rgb("#94a3b8")
#let amber   = rgb("#b45309")
#let red     = rgb("#b91c1c")

#let footer-text = "Training Arsitektur Microservices dan Cloud dengan Golang"
#let mono = ("DejaVu Sans Mono", "Menlo")

// ── Deck ───────────────────────────────────────────────────────────────────
#let deck(
  title: none,
  subtitle: none,
  day-label: none,
  client: none,
  date: none,
  instructor: "Endy Muhardin",
  vendor-name: "PT ArtiVisi Intermedia",
  body,
) = {
  assert(title != none, message: "deck: title is required")
  assert(subtitle != none, message: "deck: subtitle is required")
  assert(day-label != none, message: "deck: day-label is required")
  assert(client != none and client != "", message: "deck: client is required (sys.inputs.at(\"client\"))")
  assert(date != none, message: "deck: date is required")

  set document(title: title, author: vendor-name)
  set page(width: 960pt, height: 540pt, margin: 0pt, fill: white)
  set text(font: ("Helvetica Neue", "Arial"), fill: ink, size: 16pt, lang: "id")
  set par(leading: 0.62em, justify: false)
  show strong: set text(fill: navy-dk)

  // Inline code
  show raw.where(block: false): it => box(
    fill: panel, radius: 2pt, inset: (x: 3pt), outset: (y: 2.5pt),
    text(font: mono, size: 0.85em, fill: navy-dk, it.text),
  )
  // Block code (Go snippets, commands)
  show raw.where(block: true): it => block(
    fill: panel, stroke: (left: 2pt + navy), radius: 3pt, width: 100%,
    inset: (x: 12pt, y: 10pt),
  )[#set text(font: mono, size: 10.5pt); #set par(leading: 0.5em); #it]

  set table(stroke: 0.5pt + border, inset: 7pt, fill: (_, y) => if y == 0 { panel })
  show table.cell: set text(size: 12pt)
  show table.cell.where(y: 0): set text(weight: "bold", fill: navy-dk)

  set list(marker: text(fill: gold, weight: "bold", sym.bullet), indent: 2pt, body-indent: 8pt, spacing: 8pt)
  set enum(numbering: n => text(fill: navy, weight: "bold", str(n) + "."), spacing: 8pt)

  // Title slide
  page(fill: navy)[
    #place(top + left, dx: 56pt, dy: 44pt, image("assets/logo-artivisi-dark.svg", width: 120pt))
    #place(top + left, dx: 56pt, dy: 160pt)[
      #text(size: 12pt, fill: gold, weight: "bold", tracking: 3pt, upper(day-label))
      #v(10pt)
      #box(width: 820pt, text(size: 38pt, weight: "bold", fill: white, title))
      #v(12pt)
      #box(width: 760pt, text(size: 17pt, fill: white.transparentize(20%), subtitle))
    ]
    #place(bottom + left, dx: 56pt, dy: -44pt)[
      #line(length: 44pt, stroke: 2.5pt + gold)
      #v(10pt)
      #text(size: 9pt, fill: white.transparentize(40%), tracking: 2pt)[DISIAPKAN UNTUK]
      #v(2pt)
      #text(size: 15pt, fill: white, weight: "bold", client)
    ]
    #place(bottom + right, dx: -56pt, dy: -44pt, align(right)[
      #text(size: 13pt, fill: white, weight: "bold", instructor)
      #v(2pt)
      #text(size: 11pt, fill: white.transparentize(35%))[#vendor-name · #date]
    ])
  ]

  body
}

// ── Slide frames ───────────────────────────────────────────────────────────
#let slide-footer = context {
  set text(size: 8.5pt, fill: faint)
  grid(
    columns: (auto, 1fr, auto),
    column-gutter: 10pt,
    align: (left + horizon, left + horizon, right + horizon),
    image("assets/logo-artivisi.svg", height: 12pt),
    footer-text,
    counter(page).display("1"),
  )
}

#let slide(title: none, kicker: none, body) = page(
  margin: (x: 48pt, top: 34pt, bottom: 40pt),
  footer: slide-footer,
  footer-descent: 14pt,
)[
  #if kicker != none or title != none {
    block(spacing: 0pt, below: 22pt, stack(
      ..if kicker != none { (text(size: 10pt, fill: gold.darken(15%), weight: "bold", tracking: 1.6pt, upper(kicker)), v(12pt)) },
      ..if title != none { (
        text(size: 24pt, weight: "bold", fill: navy, title),
        v(14pt),
        line(length: 36pt, stroke: 2.2pt + gold),
      ) },
    ))
  }
  #body
]

#let section-slide(number: none, title: none, subtitle: none) = page(fill: navy-dk, footer: none)[
  #place(left + horizon, dx: 56pt)[
    #if number != none [
      #block(below: 24pt, text(size: 64pt, weight: "bold", fill: gold, top-edge: "cap-height", bottom-edge: "baseline", number))
    ]
    #box(width: 820pt, text(size: 34pt, weight: "bold", fill: white, title))
    #if subtitle != none [
      #v(8pt)
      #box(width: 760pt, text(size: 16pt, fill: white.transparentize(25%), subtitle))
    ]
    #v(14pt)
    #line(length: 56pt, stroke: 2.5pt + gold)
  ]
  #place(bottom + right, dx: -48pt, dy: -28pt,
    image("assets/logo-artivisi-dark.svg", width: 70pt))
]

// Code-focused slide: code on the left, optional explanation on the right.
#let code-slide(title: none, kicker: none, side: none, ratio: (1.6fr, 1fr), code) = slide(title: title, kicker: kicker)[
  #if side == none { code } else {
    grid(columns: ratio, column-gutter: 20pt, code, [#set text(size: 13pt); #side])
  }
]

// ── Components ─────────────────────────────────────────────────────────────
#let card(title, body, accent: navy, fill: white) = box(
  fill: fill, stroke: 0.7pt + border, radius: 5pt, inset: 12pt, width: 100%,
)[
  #box(width: 100%, stroke: (top: 2.5pt + accent), inset: (top: 7pt))[
    #text(size: 13.5pt, weight: "bold", fill: accent, title)
  ]
  #v(2pt)
  #set text(size: 12pt)
  #body
]

#let chip(txt, c: navy) = box(
  fill: c.lighten(88%), radius: 3pt, inset: (x: 7pt, y: 4pt),
  text(size: 10pt, fill: c.darken(18%), weight: "medium", txt),
)

#let bullets(size: 14pt, ..items) = {
  set text(size: size)
  for it in items.pos() {
    grid(columns: (14pt, 1fr), text(fill: gold, weight: "bold", sym.bullet), it)
    v(6pt)
  }
}

#let two-col(left, right, ratio: (1fr, 1fr), gutter: 24pt) = grid(
  columns: ratio, column-gutter: gutter, left, right,
)

// kind: "info" | "tip" | "warn"
#let note(kind: "info", body) = {
  let (c, label) = if kind == "info" { (navy, "CATATAN") }
    else if kind == "tip" { (gold.darken(15%), "TIPS") }
    else if kind == "warn" { (amber, "PERHATIAN") }
    else { panic("note: unknown kind " + repr(kind)) }
  block(
    fill: c.lighten(92%), stroke: (left: 3pt + c), radius: 2pt, width: 100%,
    inset: (x: 12pt, y: 9pt),
  )[
    #text(size: 9.5pt, fill: c, weight: "bold", tracking: 1.4pt, label)
    #v(1pt)
    #set text(size: 12.5pt)
    #body
  ]
}

// ── Diagram helpers ────────────────────────────────────────────────────────
// node kinds: "svc" (service), "db" (database), "broker" (Kafka/queue),
// "ext" (external system / client), "infra" (gateway, IdP, runner, ...).
#let node-style(kind) = {
  if kind == "svc" { (fill: navy.lighten(88%), stroke: 1.4pt + navy, text: navy-dk) }
  else if kind == "db" { (fill: gold.lighten(85%), stroke: 1.4pt + gold.darken(20%), text: gold.darken(45%)) }
  else if kind == "broker" { (fill: amber.lighten(88%), stroke: 1.4pt + amber, text: amber.darken(25%)) }
  else if kind == "ext" { (fill: white, stroke: (paint: slate, thickness: 1.2pt, dash: "dashed"), text: slate) }
  else if kind == "infra" { (fill: cream, stroke: 1.2pt + slate, text: ink) }
  else { panic("node: unknown kind " + repr(kind)) }
}

#let node-label(label, sub, color) = align(center + horizon)[
  #text(size: 12pt, weight: "bold", fill: color, label)
  #if sub != none [
    #v(-6pt)
    #text(size: 9.5pt, fill: slate, sub)
  ]
]

#let node(label, sub: none, kind: "svc", width: 120pt, height: 56pt) = {
  let s = node-style(kind)
  if kind == "db" {
    let e = 14pt
    box(width: width, height: height)[
      #place(top + left, dy: height - e, ellipse(width: width, height: e, fill: s.fill, stroke: s.stroke))
      #place(top + left, dy: e / 2, rect(width: width, height: height - e, fill: s.fill,
        stroke: (left: s.stroke, right: s.stroke)))
      #place(top + left, ellipse(width: width, height: e, fill: s.fill.lighten(40%), stroke: s.stroke))
      #place(top + left, dy: e / 2, box(width: width, height: height - e / 2, node-label(label, sub, s.text)))
    ]
  } else if kind == "broker" {
    // log segments hint at a partitioned topic
    box(width: width, height: height, fill: s.fill, stroke: s.stroke, radius: 4pt, clip: true)[
      #for i in range(1, 6) {
        place(top + left, dx: width * i / 6, line(angle: 90deg, length: 6pt, stroke: 0.8pt + s.text.lighten(40%)))
      }
      #node-label(label, sub, s.text)
    ]
  } else {
    box(width: width, height: height, fill: s.fill, stroke: s.stroke, radius: 6pt,
      node-label(label, sub, s.text))
  }
}

// Inline arrow for `flow`; dir "r" | "l" | "lr" (two-way). Optional label above.
#let arr(label: none, length: 70pt, dir: "r", dash: none, color: slate) = {
  let head(at-x, sign) = polygon(
    fill: color,
    (at-x, 0pt), (at-x - sign * 8pt, -4.5pt), (at-x - sign * 8pt, 4.5pt),
  )
  box(width: length, height: 40pt)[
    #if label != none {
      place(center + top, dy: 2pt, text(size: 9.5pt, fill: slate, label))
    }
    #place(left + top, dy: 26pt, line(length: length, stroke: (paint: color, thickness: 1.3pt, dash: dash)))
    #if dir in ("r", "lr") { place(left + top, dy: 26pt, head(length, 1)) }
    #if dir in ("l", "lr") { place(left + top, dy: 26pt, head(0pt, -1)) }
    #if dir not in ("r", "l", "lr") { panic("arr: unknown dir " + repr(dir)) }
  ]
}

// Horizontal row of nodes and arrows, vertically centred.
//   #flow(node("transfer"), arr(label: "gRPC"), node("account"))
#let flow(..items) = align(center, grid(
  columns: items.pos().len(),
  align: horizon,
  ..items.pos(),
))

// Free-form canvas. Place items with `at`, connect points with `edge`.
//   #diagram(height: 220pt,
//     at(0pt, 0pt, node("A")), at(300pt, 0pt, node("B")),
//     edge((120pt, 28pt), (300pt, 28pt), label: "REST"))
#let diagram(width: 100%, height: 220pt, ..items) = box(width: width, height: height, {
  for it in items.pos() { it }
})

#let at(x, y, body) = place(top + left, dx: x, dy: y, body)

#let edge(from, to, label: none, dash: none, color: slate, both: false, label-dx: 0pt, label-dy: -14pt) = {
  let (x1, y1) = from
  let (x2, y2) = to
  let dx = (x2 - x1) / 1pt
  let dy = (y2 - y1) / 1pt
  let len = calc.sqrt(dx * dx + dy * dy)
  assert(len > 0, message: "edge: from and to are the same point")
  let (ux, uy) = (dx / len, dy / len)
  let head(tx, ty, sx, sy) = {
    let bx = tx - sx * 9pt
    let by = ty - sy * 9pt
    place(top + left, polygon(fill: color,
      (tx, ty),
      (bx - sy * 4.5pt, by + sx * 4.5pt),
      (bx + sy * 4.5pt, by - sx * 4.5pt),
    ))
  }
  place(top + left, line(start: from, end: to, stroke: (paint: color, thickness: 1.3pt, dash: dash)))
  head(x2, y2, ux, uy)
  if both { head(x1, y1, -ux, -uy) }
  if label != none {
    let mx = (x1 + x2) / 2 + label-dx
    let my = (y1 + y2) / 2 + label-dy
    place(top + left, dx: mx - 60pt, dy: my - 6pt,
      box(width: 120pt, align(center, box(fill: white, inset: (x: 3pt, y: 1pt),
        text(size: 9.5pt, fill: slate, label)))))
  }
}

// Legend row: legend(("svc", "service"), ("db", "database"))
#let legend(..items) = {
  set text(size: 10pt, fill: slate)
  grid(columns: items.pos().len() * (auto,), column-gutter: 16pt,
    ..items.pos().map(((kind, label)) => {
      let s = node-style(kind)
      grid(columns: (12pt, auto), column-gutter: 5pt, align: horizon,
        box(width: 10pt, height: 10pt, radius: 2pt, fill: s.fill, stroke: s.stroke), label)
    })
  )
}
