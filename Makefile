# AAP Demo - Lint and CI Makefile

include lint.mk

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "AAP Demo - Lint and CI"
	@echo ""
	@echo "Usage:"
	@echo "  make lint                  Run all linters"
	@echo "  make ci                    Run all CI checks locally"
	@echo ""
	@echo "Linting Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' lint.mk | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""
