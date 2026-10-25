# Contributing

Thanks for taking the time to contribute. This project is a demonstration of disciplined delivery,
so the contribution process is intentionally strict about the same things the pipeline enforces.

---

## 1. Workflow

```bash
git checkout main && git pull
git checkout -b feat/short-description

# ... make changes ...

npm run lint && npm test
git add -A
git commit -m "feat(api): add pagination to GET /api/notes"
git push -u origin feat/short-description
gh pr create --fill
```

Open a pull request into `main`. Never push directly to `main` — CI runs on pull requests, and
`cd.yml` only reacts to a successful CI run on `main`.

---

## 2. Branch naming

| Prefix | Use |
| --- | --- |
| `feat/` | new capability |
| `fix/` | bug fix |
| `chore/` | dependencies, tooling |
| `ci/` | pipeline changes |
| `docs/` | documentation only |
| `security/` | hardening, vulnerability remediation |

---

## 3. Commit messages

Conventional Commits, imperative mood, ≤ 72 characters in the subject:

```
feat(api): reject unknown fields on POST /api/notes
fix(deploy): restore upstream when post-switch check fails
ci: pin trivy-action to v0.36.0
docs: document rollback procedure
```

Explain *why* in the body when the change is not self-evident. Reference the issue when one exists.

---

## 4. Pull request requirements

A pull request is mergeable when:

- [ ] `lint-and-test` is green;
- [ ] `build-and-scan` is green (no CRITICAL/HIGH findings);
- [ ] the SonarQube gate is green, if `SONAR_ENABLED` is set;
- [ ] new behaviour has tests, and coverage did not drop;
- [ ] documentation was updated if behaviour, configuration or operations changed;
- [ ] no secret, key, token or `.env` file is included.

---

## 5. Code standards

**JavaScript**

- CommonJS, `'use strict'`, Node 22 features only.
- No `console` — use `src/utils/logger`.
- Controllers stay thin: HTTP in, service call, response out.
- Throw `AppError` for expected failures; never `res.status(500)` by hand.
- Every new endpoint gets success **and** failure tests.

**Shell**

- `set -Eeuo pipefail` at the top of every script.
- Quote every expansion: `"$var"`, `"${var}"`.
- Use `printf` over `echo` for anything non-trivial.
- Destructive commands must be tag-scoped or name-scoped — never `docker system prune -a`,
  never `rm -rf` on a path built from an unvalidated variable.
- Run `bash -n script.sh` before committing.

**YAML**

- Validate before pushing — an unquoted `: ` inside a `run:` value is a parse error:

```bash
python3 -c "import yaml,sys; [list(yaml.safe_load_all(open(p))) for p in sys.argv[1:]]" .github/workflows/*.yml
```

---

## 6. Adding a dependency

1. Justify it — can the standard library do this?
2. Prefer a dependency with no transitive tree if the functionality is small.
3. Run `npm audit --omit=dev`.
4. Build the image and scan it: `trivy image --severity CRITICAL,HIGH <ref>`.
5. Note the addition in the pull request description.

---

## 7. Changing the pipeline

Pipeline changes deserve extra care:

- Pin any new action to a commit SHA, not a tag.
- Do not add `continue-on-error: true` to a security or test step.
- Do not grant `write` permissions to a job that does not need them.
- Never move a deployment step into a workflow that runs on `pull_request`.

---

## 8. Security issues

Do **not** open a public issue. Follow [SECURITY.md](../SECURITY.md).

---

## 9. Definition of done

- Tests and lint pass locally, not just in CI.
- The container builds and is healthy.
- Documentation reflects reality — including limitations.
- No claim of a verified result that was not actually observed.
