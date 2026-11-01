# Contributing to aap-demo

Thanks for helping. This page is how to set up the project, check your change,
commit it, and open a pull request.

The current command is developed on `main`. The published package on that
branch is version `2.0.0.dev1`. Open pull requests against `main`.

## Set up

You need Python 3.9 or newer, and git.

```bash
git clone https://github.com/RedHatOfficial/aap-demo.git
cd aap-demo
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e ".[dev]"
```

On Windows, activate the virtual environment with `.venv\Scripts\activate`.

That install uses the code in your checkout, and it includes pytest and Ruff.
After it finishes, `aap-demo version` should print `2.0.0.dev1`.

Optional: install the git hooks so formatting and commit-message checks run
when you commit.

```bash
./scripts/setup-linting.sh
```

The script creates `.venv-lint`, installs the hook tools, and turns on the
pre-commit and commit-msg hooks. Markdown checks want Node.js 20 or newer.
ShellCheck and shfmt run when you change shell scripts. The longer list of
tools is in [Linting](docs/LINTING.md).

## Test

For a Python change, run the same checks the `v2` pull request workflow runs:

```bash
python -m pytest tests/unit -q
python -m ruff check src tests
python -m ruff format --check src tests
python -m aap_demo --help
```

The usual pytest run is the unit tests. Tests marked `integration` need a real
cluster, and the pull request workflow leaves them out.

For a documentation change, lint the Markdown files you edited:

```bash
markdownlint README.md CONTRIBUTING.md --config .markdownlint.json
```

Install the linter with `npm install -g markdownlint-cli` when you do not have
it yet. `make lint-markdown` checks every tracked Markdown file.

Keep secrets out of the commit. `detect-secrets` compares the tree with
`.secrets.baseline`.

## Commit

Use [Conventional Commits](https://www.conventionalcommits.org/). The subject
line is at most 72 characters and has no period at the end.

```text
<type>: <description>

<optional body>

Signed-off-by: Your Name <you@example.com>
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`,
`ci`, `chore`, `revert`. A scope is optional, and lowercase:
`fix(deploy): honor the saved channel`.

`git commit -s` adds the `Signed-off-by` line. That line says the change is
your work and you can submit it under the project license (Apache-2.0).

Commit messages are checked with commitlint (`.commitlintrc.json`) and
Commitizen. Keep each body line within 100 characters.

## Open a pull request

Push your branch and open the pull request against `v2`.

The title uses the same conventional format as the commit subject. Fill in the
pull request template. The test plan should list the commands you ran and what
you saw. A docs-only change can list markdownlint. Save a full cluster
lifecycle test for a machine you can throw away.

The hooks refuse a commit made directly on `main` or `master`. Use a branch.

Questions are welcome as a GitHub issue.
