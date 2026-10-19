#import "../_template/panduan.typ": panduan, note, perintah

#show: panduan.with(
  label: "PANDUAN LAB",
  title: "Panduan Lab",
  subtitle: "Training Arsitektur Microservices dan Cloud dengan Golang",
  client: sys.inputs.at("client"),
  date: "Oktober 2026",
  metadata: (
    ("Training", "26 – 29 Oktober 2026"),
    ("Studi kasus", "Sistem simulasi perbankan: account, transfer, notification"),
    ("Repositori", "github.com/artivisi/training-microservices-2026-01"),
  ),
)

#include "lab-01.typ"
#include "lab-02.typ"
#include "lab-03.typ"
#include "lab-04.typ"
#include "lab-05.typ"
#include "lab-06.typ"
#include "lab-07.typ"
#include "lab-08.typ"
#include "lab-09.typ"
#include "lab-10.typ"
