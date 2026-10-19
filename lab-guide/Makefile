# The cover names the client; it is passed at build time and never committed:
#   make CLIENT="PT Contoh Klien"
SOURCE := lab-guide.typ
OUTPUT := Lab-Guide-Microservices-2026-10.pdf

.PHONY: all clean check-client

all: $(OUTPUT)

check-client:
ifndef CLIENT
	$(error CLIENT is required, e.g. make CLIENT="PT Contoh Klien")
endif

$(OUTPUT): $(SOURCE) lab-*.typ ../_template/panduan.typ | check-client
	typst compile --root .. --input client="$(CLIENT)" $(SOURCE) $(OUTPUT)

clean:
	rm -f $(OUTPUT)
