# AAP Demo - Standalone Makefile
# Includes all targets from aap-demo.mk and lint.mk

include aap-demo.mk
include lint.mk

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "AAP Demo - AAP 2.7 Deployment Tool"
	@echo ""
	@echo "Usage:"
	@echo "  make aap-demo              Deploy AAP 2.7"
	@echo "  make lint                  Run all linters"
	@echo "  make ci                    Run all CI checks locally"
	@echo ""
	@echo "Deployment Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' aap-demo.mk | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Linting Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' lint.mk | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
