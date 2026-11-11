# Makefile for aap-demo linting and quality checks

.PHONY: lint-help install-hooks lint lint-shell lint-shell-format lint-yaml lint-markdown lint-ansible format test validate-manifests check-secrets clean-lint pre-commit ci update-hooks

lint-help: ## Show linting help
	@echo ""
	@echo "Linting and Quality Targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -E '(lint|format|test|check|clean|pre-commit|ci|hooks)' | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}'
	@echo ""

install-hooks: ## Install pre-commit hooks
	@echo "Installing pre-commit hooks..."
	@command -v pre-commit >/dev/null 2>&1 || { echo "Installing pre-commit..."; pip install pre-commit; }
	@pre-commit install --hook-type pre-commit --hook-type commit-msg
	@echo "✓ Pre-commit hooks installed"

lint: lint-shell lint-shell-format lint-yaml lint-markdown lint-ansible ## Run all linters

lint-shell: ## Lint shell scripts with shellcheck
	@echo "Running shellcheck..."
	@set -e; git ls-files '*.sh' ':!.github/**' ':!docs/**' ':!*.zsh' | while IFS= read -r file; do shellcheck --severity=warning "$$file"; done
	@echo "✓ ShellCheck passed"

lint-shell-format: ## Check shell formatting with shfmt
	@echo "Running shfmt..."
	@git ls-files '*.sh' -z | xargs -0 -r -n 50 shfmt -d -i 2 -ci -bn
	@echo "✓ shfmt passed"

lint-yaml: ## Lint YAML files with yamllint
	@echo "Running yamllint..."
	@set -e; git ls-files '*.yml' '*.yaml' | while IFS= read -r file; do yamllint -c .yamllint "$$file"; done
	@echo "✓ yamllint passed"

lint-markdown: ## Lint Markdown files with markdownlint
	@echo "Running markdownlint..."
	@git ls-files '*.md' ':!.claude/**' ':!.github/**' -z | xargs -0 -r -n 50 markdownlint --config .markdownlint.json
	@echo "✓ markdownlint passed"

lint-ansible: ## Lint Ansible content with ansible-lint
	@echo "Running ansible-lint..."
	@ansible-lint --force-color --offline
	@echo "✓ ansible-lint passed"

format: ## Auto-format shell scripts and markdown
	@echo "Formatting shell scripts with shfmt..."
	@shfmt -w -i 2 -ci -bn .
	@echo "Formatting markdown files..."
	@markdownlint --fix .
	@echo "✓ Formatting complete"

test: ## Run syntax checks and non-live unit tests
	@echo "Running shell syntax checks..."
	@set -e; git ls-files '*.sh' | while IFS= read -r file; do bash -n "$$file"; done
	@echo "✓ Syntax checks passed"
	@echo "Running non-live unit tests..."
	@./test/run-unit-tests.sh
	@echo "✓ Unit tests passed"

validate-manifests: ## Validate Kubernetes manifests with kubeconform
	@echo "Validating Kubernetes manifests..."
	@git ls-files 'config/manifests/**.yaml' 'config/manifests/**.yml' 'config/crs/**.yaml' 'config/crs/**.yml' -z \
		| xargs -0 -r kubeconform --ignore-missing-schemas -summary
	@echo "✓ Manifest validation complete"

check-secrets: ## Scan for secrets with detect-secrets 1.5.0 (read-only)
	@echo "Scanning for secrets..."
	@./scripts/check-secrets.sh
	@echo "✓ No secrets detected"

clean-lint: ## Clean linting caches and temporary files
	@echo "Cleaning linting caches..."
	@find . -type f -name "*.log" -delete
	@find . -type f -name "*~" -delete
	@find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	@echo "✓ Cleanup complete"

pre-commit: ## Run pre-commit on all files
	@echo "Running pre-commit on all files..."
	@pre-commit run --all-files
	@echo "✓ Pre-commit checks passed"

ci: lint test validate-manifests check-secrets ## Run all CI checks locally
	@echo "✓ All CI checks passed"

update-hooks: ## Update pre-commit hooks to latest versions
	@echo "Updating pre-commit hooks..."
	@pre-commit autoupdate
	@echo "✓ Hooks updated"
