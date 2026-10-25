# Setup guide

Two paths: run the API locally in under a minute, or run the whole delivery stack.

---

## 1. Prerequisites

| Tool | Minimum | Check |
| --- | --- | --- |
| Node.js | 22.x | `node --version` |
| npm | 10.x | `npm --version` |
| Git | 2.40 | `git --version` |
| Docker Desktop | 24.x | `docker info` |
| AWS CLI v2 | 2.15 | `aws --version` (deployment only) |
| Trivy | 0.50+ | `trivy --version` (local scanning only) |
| GitHub CLI | 2.x | `gh --version` (repo setup only) |

On macOS: `brew install node git awscli gh trivy` (Docker Desktop is a separate install).

---

## 2. Local development

```bash
cd ~/Desktop/project-1
npm ci
npm start
```

Expected output:

```json
{"timestamp":"...","level":"info","message":"server.started","service":"notes-api","version":"1.0.0","env":"development","host":"0.0.0.0","port":3000,"pid":12345,"nodeVersion":"v22.22.2"}
```

Smoke test:

```bash
curl -s localhost:3000/health | jq
curl -s localhost:3000/api/notes | jq
curl -s -X POST localhost:3000/api/notes \
  -H 'Content-Type: application/json' \
  -d '{"title":"First note","content":"It works"}' | jq
```

### Optional: `.env`

```bash
cp .env.example .env
```

`.env` is git-ignored. It contains **no secrets** — only ports, log level and limits. If you want
`.env` loaded, either `export` the values or run with Node's built-in loader:

```bash
node --env-file=.env src/server.js
```

---

## 3. Tests and lint

```bash
npm run lint
npm test
npm run test:coverage
open coverage/lcov-report/index.html
```

The coverage gate is enforced: dropping below 80% statements/lines or 75% branches fails the run.

---

## 4. Docker

```bash
# Build for the architecture EC2 uses
docker build --platform linux/amd64 -t production-cicd-devops-project:local .

docker run -d --name notes-api -p 3000:3000 production-cicd-devops-project:local
curl -s localhost:3000/health | jq

docker inspect --format '{{.State.Health.Status}}' notes-api
docker exec notes-api id                      # uid=1000(node)
docker logs notes-api
docker stop notes-api                         # graceful: SIGTERM handled
```

Or Compose:

```bash
docker compose up -d --build
docker compose ps
docker compose logs -f app
docker compose down
```

> On Apple Silicon, `--platform linux/amd64` runs under emulation. It is slower but it is the exact
> architecture production runs, so it is the right thing to test.

---

## 5. Local security scanning

```bash
trivy image --severity CRITICAL,HIGH production-cicd-devops-project:local
trivy fs --scanners vuln,secret .
trivy image --format sarif --output trivy.sarif production-cicd-devops-project:local
```

Expected on the hardened image: `0` vulnerabilities at CRITICAL/HIGH (and, in this build, 0 at any
severity).

---

## 6. GitHub repository setup

```bash
git init -b main
git add .
git commit -m "feat: Notes API with tests, container and pipeline"
gh repo create production-cicd-devops-project --public --source=. --remote=origin --push
```

### Required repository secrets

| Secret | Used by | How to obtain |
| --- | --- | --- |
| `DOCKERHUB_USERNAME` | `ci.yml` publish | Docker Hub account name |
| `DOCKERHUB_TOKEN` | `ci.yml` publish | Docker Hub → Account settings → Security → New access token (**Read & Write**) |
| `SONAR_TOKEN` | `sonar` job | SonarQube → My Account → Security |

### Required repository variables

| Variable | Example | Purpose |
| --- | --- | --- |
| `PUBLISH_ENABLED` | `true` | Enables the Docker Hub publish job |
| `SONAR_ENABLED` | `true` | Enables the SonarQube job |
| `DEPLOY_ENABLED` | `true` | Enables the CD deploy job |
| `SONAR_HOST_URL` | `https://sonarcloud.io` | Sonar endpoint |
| `AWS_REGION` | `us-east-1` | Deployment region |
| `EC2_INSTANCE_ID` | `i-0abc...` | Target instance |
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::...:role/gha-deploy` | OIDC role for CD |
| `PUBLIC_BASE_URL` | `http://1.2.3.4` | Post-deploy verification |

Add them with:

```bash
gh secret set DOCKERHUB_USERNAME
gh secret set DOCKERHUB_TOKEN
gh secret set SONAR_TOKEN
gh variable set SONAR_ENABLED --body "true"
gh variable set AWS_REGION --body "us-east-1"
gh variable set EC2_INSTANCE_ID --body "i-..."
```

Never paste a secret into a file in the repository.

---

## 7. AWS setup

```bash
aws sts get-caller-identity          # confirm the account and identity
aws configure list                   # confirm the region

./scripts/provision-aws.sh --dry-run # plan + cost estimate, creates nothing
./scripts/provision-aws.sh           # create SG, IAM role/profile, instance
```

Then, once, on the instance:

```bash
sudo ./scripts/bootstrap-server.sh
```

Full details: [deployment.md](deployment.md).

---

## 8. Verification checklist

```bash
npm run lint                                    # 0 problems
npm test                                        # 33 passed
docker build --platform linux/amd64 -t x .      # success
docker run -d --name t -p 3000:3000 x && curl -s localhost:3000/health
docker exec t id                                # uid=1000
trivy image --severity CRITICAL,HIGH x          # 0 findings
./scripts/health-check.sh --url http://localhost:3000
```
