// Shared template for participant documents (setup guide, lab guide).
// Same palette and chrome as the ArtiVisi proposal template; cover label is a parameter.
//
//   #import "../_template/panduan.typ": panduan, note, perintah
//   #show: panduan.with(label: "PANDUAN PERSIAPAN", title: "...", ...)

#let navy   = rgb("#2e3192")
#let gold   = rgb("#58c034")
#let cream  = rgb("#f8f7fa")
#let slate  = rgb("#4b5563")
#let border = rgb("#cbd5e1")
#let panel  = rgb("#eef0f9")

#let note(body) = block(
  fill: cream,
  stroke: (left: 2pt + gold),
  width: 100%,
  inset: (x: 1em, y: 0.7em),
  radius: 2pt,
)[#body]

// Command block: monospace, shaded, breakable.
#let perintah(body) = block(
  fill: panel,
  width: 100%,
  inset: (x: 0.9em, y: 0.65em),
  radius: 2pt,
  breakable: true,
)[#set text(size: 8.5pt); #set par(justify: false); #body]

#let panduan(
  label: "",
  title: "",
  subtitle: none,
  client: "",
  date: "",
  metadata: (),
  vendor-name: "PT ArtiVisi Intermedia",
  vendor-contact: "endy@artivisi.com · artivisi.com",
  body,
) = {
  set document(title: title, author: vendor-name)
  set text(font: ("New Computer Modern", "Times New Roman"), size: 10.5pt, lang: "id")
  set par(justify: true, leading: 0.65em)
  show raw: set text(font: ("DejaVu Sans Mono", "Menlo"), size: 8.5pt)

  // Cover
  set page(paper: "a4", margin: 0pt, numbering: none)
  block(fill: navy, width: 100%, height: 10cm, inset: (x: 2.5cm, top: 2cm, bottom: 1.6cm))[
    #set text(fill: white)
    #image("assets/logo-artivisi-dark.svg", width: 4.5cm)
    #v(1.2cm)
    #text(size: 10pt, tracking: 3pt, fill: gold)[#label]
    #v(0.4em)
    #text(size: 22pt, weight: "bold")[#title]
    #if subtitle != none {
      v(0.3em)
      text(size: 12.5pt, fill: rgb("#e2e8f0"))[#subtitle]
    }
  ]
  block(width: 100%, inset: (x: 2.5cm, top: 1.6cm, bottom: 1.2cm))[
    #block(fill: cream, stroke: (left: 3pt + gold), width: 100%, inset: (x: 1.2em, y: 0.9em))[
      #text(size: 8pt, fill: slate, tracking: 2pt)[DISIAPKAN UNTUK]
      #v(0.25em)
      #text(size: 14pt, weight: "bold", fill: navy)[#client]
    ]
    #v(1.2cm)
    #if metadata.len() > 0 {
      table(
        columns: (auto, 1fr),
        stroke: (x, y) => (bottom: 0.4pt + border),
        inset: (x: 0pt, y: 8pt),
        align: (left, right),
        ..metadata.map(((k, v)) => (text(fill: slate)[#k], text(weight: "bold", fill: navy)[#v])).flatten()
      )
    }
  ]
  v(1fr)
  block(fill: navy, width: 100%, height: 2.4cm, inset: (x: 2.5cm, y: 0.7cm))[
    #set text(fill: white, size: 9pt)
    #grid(
      columns: (1fr, auto),
      align: (left + horizon, right + horizon),
      [#text(weight: "bold", size: 10pt)[#vendor-name] \ #text(fill: rgb("#cbd5e1"), size: 8.5pt)[#vendor-contact]],
      text(fill: gold, weight: "bold")[#date],
    )
  ]
  pagebreak()

  // Body
  set page(
    paper: "a4",
    margin: (top: 2.5cm, bottom: 2.2cm, x: 2.2cm),
    header: context {
      set text(size: 8pt, fill: slate)
      grid(columns: (1fr, auto), text(weight: "bold", fill: navy, tracking: 1.5pt)[ARTIVISI], title)
      v(-0.4em)
      line(length: 100%, stroke: 0.3pt + border)
    },
    footer: context {
      line(length: 100%, stroke: 0.3pt + border)
      v(-0.2em)
      set text(size: 8pt, fill: slate)
      grid(columns: (1fr, auto, 1fr), align: (left, center, right),
        vendor-name, counter(page).display(), date)
    },
  )
  counter(page).update(1)

  set heading(numbering: "1.1", supplement: [bagian])
  show heading.where(level: 1): it => {
    set text(size: 14pt, weight: "bold", fill: navy)
    block(above: 1.4em, below: 0.4em)[#it]
    v(-0.6em)
    line(length: 100%, stroke: 0.6pt + gold)
    v(0.55em)
  }
  show heading.where(level: 2): it => {
    set text(size: 11.5pt, weight: "bold", fill: navy)
    block(above: 1.1em, below: 0.7em)[#it]
  }
  show heading.where(level: 3): it => {
    set text(size: 10.5pt, weight: "bold", fill: slate)
    block(above: 0.85em, below: 0.55em)[#it]
  }
  set table(stroke: 0.4pt + border, inset: 6pt, fill: (_, y) => if y == 0 { panel } else { none })
  show table.cell: set par(justify: false)
  show table.cell.where(y: 0): set text(weight: "bold")

  body
}
