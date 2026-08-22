# WaveDrom waveform diagrams only. Block diagrams and FSMs are inline
# Mermaid code blocks in the markdown docs (rendered natively by GitHub)
# and have no build step here.
WAVEDROM := npx wavedrom-cli

WF_SRC := $(wildcard src/wf-*.json)
WF_SVG := $(patsubst src/%.json,svg/%.svg,$(WF_SRC))

.PHONY: all clean regen

all: $(WF_SVG)

svg/%.svg: src/%.json
	$(WAVEDROM) -i $< -s $@

regen:
	@for f in $$(git diff --name-only -- src/); do \
	  svg=svg/$$(basename "$${f%.*}").svg; \
	  echo "Rebuilding $$svg from $$f"; \
	  $(MAKE) "$$svg"; \
	done

clean:
	rm -f svg/*.svg
