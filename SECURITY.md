# Security Policy

## Supported versions

This is a portfolio project with a single maintained branch.

| Version | Supported |
| --- | --- |
| `main` | Yes |
| anything else | No |

---

## Reporting a vulnerability

**Do not open a public issue for a security problem.**

Use GitHub's private reporting: **Security → Advisories → Report a vulnerability** on the repository.

Please include:

- affected endpoint, file or workflow;
- reproduction steps or a proof of concept;
- impact assessment (what an attacker gains);
- suggested remediation, if you have one.

Expect an initial response within 7 days. This is a personal project, not a commercial service, so
there is no formal SLA or bug bounty.

---

## Security controls implemented

### Secrets management

| Control | Implementation |
| --- | --- |
| No secrets in source | `.gitignore` blocks `.env*`, `*.pem`, `*.key`, `id_rsa*`, `credentials`, `.deploy/` |
| No secrets in the image | `.dockerignore` excludes the same patterns; the image only receives non-sensitive `ENV` |
| CI secrets | GitHub Actions Secrets (`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`, `SONAR_TOKEN`) |
| Cloud credentials | GitHub OIDC → `sts:AssumeRoleWithWebIdentity`; no long-lived AWS access key in CI |
| Server credentials | No registry credentials on the host (public image); administration via SSM |
| Runtime config | `.env.example` contains placeholders only |
| Log hygiene | Bodies and headers are never logged; sensitive keys are redacted defensively |

### Application

| Control | Implementation |
| --- | --- |
| Security headers | `helmet()` — CSP, HSTS, `X-Content-Type-Options`, frame options, referrer policy |
| Header disclosure | `app.disable('x-powered-by')`, Nginx `server_tokens off` |
| Input validation | Type, presence, length and unknown-field checks; UUID format enforced on path params |
| Body size | 32 kB (Express) and 64 kB (Nginx) |
| Error disclosure | Generic 500; stack traces logged only, never returned — asserted by a test |
| Request tracing | `X-Request-Id` correlation, generated or validated from the client |
| Storage limits | `MAX_NOTES` caps in-memory growth |
| Shutdown | `SIGTERM` handled, in-flight requests drained, forced exit as a backstop |

### Container

| Control | Implementation |
| --- | --- |
| Non-root | `USER node` (uid 1000) |
| Immutable code | `/app` owned by `root`; process cannot write to it (verified) |
| Read-only rootfs | `--read-only` with `--tmpfs /tmp` |
| No privilege escalation | `no-new-privileges`, `cap_drop: ALL` |
| Resource limits | `--memory 256m` |
| Minimal runtime | Multi-stage build, `npm ci --omit=dev`, npm removed from the final image |
| Patched base | `apk upgrade` at build time |

### Network and cloud

| Control | Implementation |
| --- | --- |
| Least-privilege ingress | Only `tcp/80` public; `tcp/22` restricted to the operator `/32` |
| No public app port | Containers bind `127.0.0.1`; Nginx is the only listener on 80 |
| Instance metadata | IMDSv2 required (`HttpTokens=required`) |
| Admin access | AWS Systems Manager; SSH is optional and IP-restricted |
| IAM | Instance role limited to `AmazonSSMManagedInstanceCore` |
| Encryption | Root EBS volume encrypted |
| Resource scoping | All resources tagged; `cleanup-aws.sh` only touches tagged resources |

### Supply chain

| Control | Implementation |
| --- | --- |
| Reproducible installs | `npm ci` from `package-lock.json` |
| No arbitrary install scripts | `npm ci --ignore-scripts` |
| Pinned CI actions | Every third-party action pinned to a commit SHA |
| Pinned base image | `node:22.22.2-alpine` |
| Vulnerability scanning | Trivy on dependencies **and** the built image; blocks CRITICAL/HIGH |
| Secret scanning | Trivy `secret` scanner in CI |
| Code quality gate | SonarQube, when configured |

---

## Scanner policy

Trivy runs with `--ignore-unfixed`, and `.trivyignore` is intentionally empty. Rationale:

- A finding with no available fix cannot be remediated by any action this pipeline can take; blocking
  on it would only encourage blanket suppression.
- Any genuine exception must document the CVE, why it is not exploitable here, an owner and a
  review-by date — see the header of `.trivyignore`.

Trivy is a **static** scanner. It reports known vulnerabilities in installed versions; it does not
detect exploitation, unreachable-but-vulnerable code paths, or zero-days. Runtime protection
(Falco, GuardDuty Runtime Monitoring, seccomp/AppArmor) is not implemented — see the README's
"Future improvements".

---

## Known limitations relevant to security

- **No authentication or authorisation.** The API is public and unauthenticated by design; it is a
  pipeline demonstration, not a multi-tenant service.
- **In-memory storage.** No persistence, therefore no data-at-rest concerns — and no durability.
- **No HTTPS.** No domain or certificate is configured; traffic to the instance is plain HTTP.
- **No rate limiting.** A public deployment could be abused; add a limiter before exposing real data.
- **Single instance.** No WAF, no DDoS protection beyond what AWS provides by default.
