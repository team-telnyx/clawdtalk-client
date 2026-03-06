# ClawdTalk Client - Release Makefile
#
# Commands:
#   make release-local    Build zip + checksum locally
#   make bump-patch       Bump patch version (2.0.4 → 2.0.5)
#   make bump-minor       Bump minor version (2.0.4 → 2.1.0)
#   make clean            Remove built artifacts
#   make version          Print current version
#
# Release workflow:
#   1. make bump-patch                    (or bump-minor)
#   2. git checkout -b chore/bump-vX.Y.Z
#   3. git add package.json && git commit -m "chore: bump to vX.Y.Z"
#   4. git push -u origin chore/bump-vX.Y.Z
#   5. Merge PR to main
#   6. git checkout main && git pull
#   7. git tag vX.Y.Z && git push --tags
#   8. GitHub Actions builds zip + checksum and creates the release automatically
#
# Manual release (if Actions unavailable):
#   1. make release-local
#   2. Follow the printed gh command to publish

VERSION := $(shell jq -r .version package.json)
ARCHIVE := clawdtalk-client-$(VERSION).zip
CHECKSUM := clawdtalk-client-$(VERSION).sha256

EXCLUDE := ".git/*" "node_modules/*" ".backup/*" ".connect.log" ".connect.pid" \
           ".DS_Store" ".missions_state.json" "clawdtalk-client-*.zip" \
           "clawdtalk-client-*.sha256" "skill-config.json"

.PHONY: release-zip release-checksum release-local clean bump-patch bump-minor version

version:
	@echo $(VERSION)

release-zip:
	@echo "Building $(ARCHIVE)..."
	@rm -f clawdtalk-client-*.zip
	@zip -r $(ARCHIVE) . $(addprefix -x ,$(EXCLUDE))
	@echo "✓ Built $(ARCHIVE)"

release-checksum: release-zip
	@echo "Generating $(CHECKSUM)..."
	@shasum -a 256 $(ARCHIVE) > $(CHECKSUM)
	@cat $(CHECKSUM)
	@echo "✓ Generated $(CHECKSUM)"

release-local: release-checksum
	@echo ""
	@echo "Release artifacts ready:"
	@echo "  $(ARCHIVE)"
	@echo "  $(CHECKSUM)"
	@echo ""
	@echo "To publish manually:"
	@echo "  gh release create v$(VERSION) $(ARCHIVE) $(CHECKSUM) --repo team-telnyx/clawdtalk-client --title v$(VERSION)"

clean:
	@rm -f clawdtalk-client-*.zip clawdtalk-client-*.sha256
	@echo "✓ Cleaned release artifacts"

bump-patch:
	@CURRENT=$(VERSION); \
	MAJOR=$$(echo $$CURRENT | cut -d. -f1); \
	MINOR=$$(echo $$CURRENT | cut -d. -f2); \
	PATCH=$$(echo $$CURRENT | cut -d. -f3); \
	NEW="$$MAJOR.$$MINOR.$$((PATCH + 1))"; \
	jq --arg v "$$NEW" '.version = $$v' package.json > package.json.tmp && mv package.json.tmp package.json; \
	echo "✓ Bumped $$CURRENT → $$NEW"

bump-minor:
	@CURRENT=$(VERSION); \
	MAJOR=$$(echo $$CURRENT | cut -d. -f1); \
	MINOR=$$(echo $$CURRENT | cut -d. -f2); \
	NEW="$$MAJOR.$$((MINOR + 1)).0"; \
	jq --arg v "$$NEW" '.version = $$v' package.json > package.json.tmp && mv package.json.tmp package.json; \
	echo "✓ Bumped $$CURRENT → $$NEW"
