# The title slide names the client; it is passed at build time and never committed:
#   make CLIENT="PT Contoh Klien"
#   make sample CLIENT="PT Contoh Klien"   # template showcase (hari-0-contoh.typ)
DAYS     := 1 2 3 4
OUTPUTS  := $(foreach d,$(DAYS),Deck-Hari-$(d)-Microservices-2026-10.pdf)
SAMPLE   := Deck-Hari-0-Contoh.pdf
TEMPLATE := ../_template/deck.typ $(wildcard ../_template/assets/*)

.PHONY: all sample clean check-client

all: $(OUTPUTS)

check-client:
ifndef CLIENT
	$(error CLIENT is required, e.g. make CLIENT="PT Contoh Klien")
endif

Deck-Hari-%-Microservices-2026-10.pdf: hari-%.typ $(TEMPLATE) | check-client
	typst compile --root .. --input client="$(CLIENT)" $< $@

sample: $(SAMPLE)

$(SAMPLE): hari-0-contoh.typ $(TEMPLATE) | check-client
	typst compile --root .. --input client="$(CLIENT)" $< $@

clean:
	rm -f $(OUTPUTS) $(SAMPLE)
