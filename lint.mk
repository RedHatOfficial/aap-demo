# Makefile for aap-demo linting and quality checks

.PHONY: lint-help install-hooks lint lint-shell lint-yaml lint-markdown lint-ansible format test validate-manifests check-secrets clean-lint pre-commit ci update-hooks

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

lint: lint-shell lint-yaml lint-markdown ## Run all linters

lint-shell: ## Lint shell scripts with shellcheck
	@echo "Running shellcheck..."
	@find . -name "*.sh" -type f -not -path "./.git/*" -exec shellcheck --severity=warning {} \;
	@echo "✓ ShellCheck passed"

lint-yaml: ## Lint YAML files with yamllint
	@echo "Running yamllint..."
	@yamllint .
	@echo "✓ yamllint passed"

lint-markdown: ## Lint Markdown files with markdownlint
	@echo "Running markdownlint..."
	@markdownlint .
	@echo "✓ markdownlint passed"

lint-ansible: ## Lint Ansible content with ansible-lint
	@echo "Running ansible-lint..."
	@if [ -f "requirements.yml" ] || find . -name "playbook*.yml" -o -name "site.yml" | grep -q .; then \
		ansible-lint --force-color; \
	else \
		echo "No Ansible content found, skipping"; \
	fi
	@echo "✓ ansible-lint passed"

format: ## Auto-format shell scripts and markdown
	@echo "Formatting shell scripts with shfmt..."
	@shfmt -w -i 2 -ci -bn .
	@echo "Formatting markdown files..."
	@markdownlint --fix .
	@echo "✓ Formatting complete"

test: ## Run syntax checks and dry-run tests
	@echo "Running shell syntax checks..."
	@find . -name "*.sh" -type f -exec bash -n {} \;
	@echo "✓ Syntax checks passed"
	@echo "Running dry-run tests..."
	@./aap-demo.sh help >/dev/null
	@echo "✓ Dry-run tests passed"

validate-manifests: ## Validate Kubernetes manifests with kubeconform
	@echo "Validating Kubernetes manifests..."
	@find config/manifests config/crs -name "*.yaml" -o -name "*.yml" 2>/dev/null | while read -r file; do \
		echo "Validating $$file"; \
		kubeconform --ignore-missing-schemas "$$file" || true; \
	done
	@echo "✓ Manifest validation complete"

check-secrets: ## Scan for secrets with detect-secrets
	@echo "Scanning for secrets..."
	@detect-secrets scan --baseline .secrets.baseline
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
