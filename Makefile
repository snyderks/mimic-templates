# A template is a folder under templates/ in the source form, with a template.json
# and a file for each layout beside the PNGs of its parts. The engine's validate
# and pack commands check it and build its bundle, at the engine release named by
# ENGINE_VERSION, which is the one CI uses.
#
#   make validate TEMPLATE=m15     check a source folder and report every problem
#   make bundle   TEMPLATE=m15     build build/m15.mimic from the source folder
#   make release  TEMPLATE=m15     upload that bundle to the release release-please made
#   make convert  TEMPLATE=m15     rebuild a template's source folder from its PSDs
#   make check-convert TEMPLATE=m15  rebuild it and compare it with the checked in folder
#   make convert-family FAMILY=m15-family        rebuild a family from its members' PSDs
#   make check-convert-family FAMILY=m15-family   rebuild it and compare it with the checked in folder
#
# TEMPLATE selects the template, and FAMILY a family of them.
#
# A template converted from Proxyshop's PSDs has a recipe in recipes/, which says
# which layers of which PSD make each part. convert runs the engine's psdconvert
# command on it with the PSDs in PSD_DIR, which git ignores, and writes the
# source folder to build/convert. PSDCONVERT names the command, so a local engine
# checkout can stand in for a release, as in PSDCONVERT=../mimic/bin/psdconvert
#
# A family merges several converted templates that each cover different card
# shapes into one, the way m15-family's normal, split, transform, planeswalker,
# saga and class (among others) each come from Proxyshop's own separate PSDs.
# recipes/<family>/members.txt lists the member ids, one per line, in the order
# tplmerge merge takes them; a rename it makes for a name two members define
# differently depends on that order, so changing it changes the bytes a member
# that collides with another ends up with. convert-family runs convert once per
# member and then tplmerge merge over the results. TPLMERGE names the merge
# command, the same way PSDCONVERT does for convert

TEMPLATE ?= m15
ENGINE_VERSION ?= v0.18.0
VERSION = $(shell jq -r .version templates/$(TEMPLATE)/template.json)

FAMILY ?= m15-family
FAMILY_ID = $(shell jq -r .id templates/$(FAMILY)/template.json)
FAMILY_NAME = $(shell jq -r .name templates/$(FAMILY)/template.json)
FAMILY_MEMBERS = $(shell cat recipes/$(FAMILY)/members.txt)

PSD_DIR ?= psd
CONVERT_ENGINE_VERSION ?= $(ENGINE_VERSION)
PSDCONVERT ?= GOWORK=off go run github.com/odevine/mimic/engine/cmd/psdconvert@$(CONVERT_ENGINE_VERSION)
TPLMERGE ?= GOWORK=off go run github.com/odevine/mimic/engine/cmd/tplmerge@$(CONVERT_ENGINE_VERSION)

.PHONY: validate bundle release convert check-convert convert-family check-convert-family

# validate checks a template in the source form, which is stricter than the app is
validate:
	GOWORK=off go run github.com/odevine/mimic/engine/cmd/validate@$(ENGINE_VERSION) templates/$(TEMPLATE)

# bundle builds a template into a bundle, with the version in its template.json.
# The same folder always builds the same bytes
bundle:
	mkdir -p build
	GOWORK=off go run github.com/odevine/mimic/engine/cmd/pack@$(ENGINE_VERSION) templates/$(TEMPLATE) -o build/$(TEMPLATE).mimic

# release uploads a locally built bundle to the tag release-please created and
# triggers the catalog rebuild. Routine releases run in CI, and this is the manual
# path for one cut from your machine. Build the bundle first with bundle
release:
	gh release upload $(TEMPLATE)/v$(VERSION) build/$(TEMPLATE).mimic --clobber
	gh workflow run index.yml

# convert builds a template's source folder from its recipe and PSDs
convert:
	rm -rf build/convert/$(TEMPLATE)
	$(PSDCONVERT) build -recipe recipes/$(TEMPLATE).json -psd-dir $(PSD_DIR) -o build/convert/$(TEMPLATE)

# check-convert rebuilds a template from its PSDs and fails unless every file it
# writes matches the checked in folder byte for byte
check-convert: convert
	cd build/convert/$(TEMPLATE) && find . -type f | sort > ../$(TEMPLATE).files
	cd build/convert/$(TEMPLATE) && find . -type f | sort | xargs shasum -a 256 > ../$(TEMPLATE).sums
	cd templates/$(TEMPLATE) && shasum -a 256 -c ../../build/convert/$(TEMPLATE).sums --quiet
	cd templates/$(TEMPLATE) && find . -type f ! -name README.md ! -name CHANGELOG.md | sort | diff - ../../build/convert/$(TEMPLATE).files
	@echo "all $$(wc -l < build/convert/$(TEMPLATE).files | tr -d ' ') converted files match templates/$(TEMPLATE)"

# convert-family rebuilds every member recipe under recipes/<family>/ and merges
# the results into one folder, in the order members.txt lists them
convert-family:
	rm -rf build/convert/$(FAMILY) build/convert/$(FAMILY)-members
	mkdir -p build/convert/$(FAMILY)-members
	for id in $(FAMILY_MEMBERS); do \
		$(PSDCONVERT) build -recipe recipes/$(FAMILY)/$$id.json -psd-dir $(PSD_DIR) -o build/convert/$(FAMILY)-members/$$id || exit 1; \
	done
	$(TPLMERGE) merge -out build/convert/$(FAMILY) -id $(FAMILY_ID) -name "$(FAMILY_NAME)" \
		$(foreach id,$(FAMILY_MEMBERS),build/convert/$(FAMILY)-members/$(id))

# check-convert-family rebuilds a family from its members' PSDs and fails unless
# every file it writes matches the checked in folder byte for byte. template.json
# is compared with its version and description left out, since those are kept by
# hand (version by release-please, once the family is registered with it) rather
# than written by tplmerge merge
check-convert-family: convert-family
	cd build/convert/$(FAMILY) && find . -type f | sort > ../$(FAMILY).files
	cd build/convert/$(FAMILY) && find . -type f ! -name template.json | sort | xargs shasum -a 256 > ../$(FAMILY).sums
	cd templates/$(FAMILY) && shasum -a 256 -c ../../build/convert/$(FAMILY).sums --quiet
	jq 'del(.version, .description)' templates/$(FAMILY)/template.json > build/convert/$(FAMILY).kept.json
	jq 'del(.version, .description)' build/convert/$(FAMILY)/template.json > build/convert/$(FAMILY).fresh.json
	diff build/convert/$(FAMILY).kept.json build/convert/$(FAMILY).fresh.json
	cd templates/$(FAMILY) && find . -type f ! -name README.md ! -name CHANGELOG.md | sort | diff - ../../build/convert/$(FAMILY).files
	@echo "all $$(wc -l < build/convert/$(FAMILY).files | tr -d ' ') converted files match templates/$(FAMILY)"
