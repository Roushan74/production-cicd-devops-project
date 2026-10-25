# Deployment guide

How a commit travels from `git push` to a verified production endpoint.

> **Current status: no AWS resources exist.**
>
> The infrastructure described here was **not** created — the account owner declined to incur the
> ~$11.9/month cost during this build. Everything below is implemented and syntax-checked, and the
> deployment mechanics were exercised end-to-end against a containerised Nginx on the development
> machine (§6). Nothing in this document is a claim that a real EC2 deployment happened.
>
> To actually deploy: run §2, then §3. Total time ~10 minutes, cost as stated in §9.

---

## 1. Deployment model

```
merge to main
   │
   ├─ CI: lint → test → sonar → build → trivy → push image:<GIT_SHA>
   │
   └─ CD (workflow_run, only if CI succeeded)
          │  GitHub OIDC → AWS STS → role
          ▼
       SSM SendCommand  ──►  EC2
                                │
                                ├─ deploy.sh --image repo:<SHA>
                                │     ├─ docker pull
                                │     ├─ run candidate in idle slot
                                │     ├─ poll /health (+ expected version)
                                │     ├─ rewrite upstream → nginx -t → reload
                                │     ├─ verify through Nginx
                                │     └─ stop old container
                                │
                                └─ health-check.sh (from the runner, public URL)
```

Nothing is deployed by hand in the normal flow. Manual deployment is supported for recovery.

---

## 2. First-time infrastructure

```bash
aws sts get-caller-identity
./scripts/provision-aws.sh --dry-run
./scripts/provision-aws.sh
```

What it creates (idempotently, all tagged `Project=production-cicd-devops-project`):

| Resource | Detail |
| --- | --- |
| Security group | inbound 80 `0.0.0.0/0`; inbound 22 from your `/32`; egress all |
| IAM role | `<project>-ec2-role` + `AmazonSSMManagedInstanceCore` |
| Instance profile | `<project>-ec2-profile` |
| EC2 instance | `t3.micro`, Amazon Linux 2023, 8 GiB gp3 (encrypted), IMDSv2 required |

Outputs are written to `.deploy/aws-state.env` (git-ignored):

```
INSTANCE_ID=i-0123456789abcdef0
PUBLIC_IP=54.1.2.3
SECURITY_GROUP_ID=sg-0abc...
```

### Server bootstrap (once)

```bash
# Copy the repo to the instance (or clone it) and run:
sudo ./scripts/bootstrap-server.sh
```

This installs Docker and Nginx, enables both at boot, creates `/opt/notes-api/state`, installs
`/etc/nginx/conf.d/notes-api.conf` and `/etc/nginx/notes-upstream.conf`, validates with `nginx -t`,
and adds log rotation for `/var/log/nginx/notes_api.*.log`.

---

## 3. Deploying

### From CI (normal path)

Automatic on a successful CI run on `main`. Manual:

```bash
gh workflow run cd.yml -f image_tag=<sha>
```

### From a laptop, through SSM

```bash
./scripts/ssm-deploy.sh \
  --instance i-0123456789abcdef0 \
  --region us-east-1 \
  --image <dockerhub-user>/production-cicd-devops-project:<sha> \
  --rollback-on-failure
```

`--rollback-on-failure` re-deploys the recorded previous image if the deployment fails.

### On the host

```bash
cd /opt/notes-api
./deploy.sh --image <ref> --expect-version 1.1.0
```

---

## 4. What the deploy actually does

| Step | Command | On failure |
| --- | --- | --- |
| 1 | `docker pull` (3 attempts) | abort; production untouched |
| 2 | `docker run` candidate in idle slot | abort; candidate removed |
| 3 | poll `127.0.0.1:<slot>/health` ≤ 90 s | abort; candidate removed; logs printed |
| 4 | rewrite upstream file | abort; traffic never moved |
| 5 | `nginx -t` | abort; old config still loaded |
| 6 | `nginx -s reload` | abort; trap restores upstream |
| 7 | `curl http://127.0.0.1/health` through Nginx | **automatic revert** of upstream |
| 8 | record state, stop old container | warn only |

Step 7 is the important one: it proves the *public path* works, not just the container.

---

## 5. Rollback

```bash
./scripts/rollback.sh --dry-run     # show what would happen
./scripts/rollback.sh               # redeploy the recorded previous image
./scripts/rollback.sh --image <ref> # to a specific image
```

Rollback is a normal deployment of the previous image, so it is health-checked before it takes
traffic. The previous image is always still on disk: `deploy.sh` only prunes dangling layers, never
tagged images.

---

## 6. Verified behaviour (real output)

> These transcripts come from executing `deploy.sh` and `rollback.sh` on this machine against a
> containerised Nginx and two image versions — the same scripts and the same Nginx configuration
> files that would run on EC2, with only the upstream host and ports overridden through the
> documented environment variables. No AWS resource was involved.

Blue/green switch with 120 concurrent requests during the change:

```
$ ./scripts/deploy.sh --image production-cicd-devops-project:v1.1.0 --no-pull --expect-version 1.1.0
[deploy] Active slot : blue (production-cicd-devops-project:v1.0.0)
[deploy] Target slot : green (port 3101)
[deploy] Image       : production-cicd-devops-project:v1.1.0
[deploy] Starting candidate notes-bg-green on 127.0.0.1:3101...
[deploy] Waiting up to 90s for /health on port 3101...
[deploy] Candidate is healthy: {"application":"notes-api","status":"ok","version":"1.1.0",...}
[deploy] Pointing Nginx upstream at 3101...
nginx: configuration file /etc/nginx/nginx.conf test is successful
[deploy] Nginx reloaded gracefully
[deploy] Verifying public path http://127.0.0.1:8080/health...
[deploy] Stopping previous container notes-bg-blue...
[deploy] SUCCESS: production-cicd-devops-project:v1.1.0 is live in slot green (port 3101)

# request codes observed during the switch:
#  120 200        <- zero failures
```

Rejected deployment (unmet version expectation):

```
$ ./scripts/deploy.sh --image ...:v1.1.0 --expect-version 9.9.9 --timeout 10
[deploy] Waiting up to 10s for /health on port 3101...
[deploy] ERROR: Candidate did not become healthy
[deploy] WARNING: Removing failed candidate notes-bg-green
[deploy] WARNING: Production traffic was NOT moved to the new version.

# traffic still served v1.0.0; state file unchanged; upstream unchanged
```

Rollback:

```
$ ./scripts/rollback.sh
[rollback] Current image : production-cicd-devops-project:v1.1.0
[rollback] Rollback to   : production-cicd-devops-project:v1.0.0
[deploy] SUCCESS: production-cicd-devops-project:v1.0.0 is live in slot blue (port 3100)

$ curl -s http://127.0.0.1:8080/health | jq -c '{version}'
{"version":"1.0.0"}
```

---

## 7. Operating notes

| Task | Command |
| --- | --- |
| Which version is live? | `cat /opt/notes-api/state/active_image` |
| What was live before? | `cat /opt/notes-api/state/previous_image` |
| Container health | `docker ps --format '{{.Names}}\t{{.Status}}'` |
| App logs | `docker logs --tail 100 notes-api-blue` |
| Nginx access log | `tail -f /var/log/nginx/notes_api.access.log` |
| Nginx error log | `tail -f /var/log/nginx/notes_api.error.log` |
| Reload Nginx by hand | `nginx -t && nginx -s reload` |
| Disk usage | `docker system df` |

### Disk growth

Images accumulate because rollback needs them. Docker logs are capped (10 MB × 3). To reclaim space
safely:

```bash
docker image prune -f          # dangling layers only - safe
docker image ls --filter "dangling=false"   # review before deleting anything else
```

Never run `docker system prune -a --volumes` on this host: it would delete the rollback artefacts.

---

## 8. Why SSM instead of SSH for CI

| Concern | SSH from a runner | SSM Run Command |
| --- | --- | --- |
| Inbound port | must be open to the runner's IP (which changes) | none |
| Credential in CI | long-lived private key | short-lived OIDC token |
| Audit trail | host `auth.log` | CloudTrail + SSM command history |
| Access revocation | rotate the key everywhere | remove the IAM permission |

SSH from the operator's `/32` remains available for manual recovery, but the pipeline does not need
it.

---

## 9. Cost control during deployment

- No NAT gateway, no ALB, no EKS.
- One instance, one 8 GiB volume, one public IPv4.
- `docker image prune -f` (dangling only) runs after each deploy.
- `scripts/cleanup-aws.sh --dry-run` lists everything tagged for this project before you delete it.

Stopping the instance does **not** stop EBS or public-IPv4 charges. Terminating it does (the volume
is `DeleteOnTermination=true`).
