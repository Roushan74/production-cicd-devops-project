# Troubleshooting

Symptom → cause → fix, ordered by where in the pipeline the failure appears.

---

## 1. Local application

### `Invalid configuration: PORT="abc" must be an integer between 1 and 65535`

Configuration is validated at boot by design. Fix the environment variable; do not remove the
validation.

```bash
echo $PORT          # inspect
PORT=3000 npm start
```

### `EADDRINUSE: address already in use :::3000`

```bash
lsof -nP -iTCP:3000 -sTCP:LISTEN
kill -TERM <pid>     # SIGTERM triggers the graceful shutdown path
```

### Server exits immediately with no error

Check for a thrown error during module load — `config/index.js` validates eagerly:

```bash
node src/server.js; echo "exit=$?"
```

---

## 2. Tests

### `Coverage threshold for statements (80%) not met`

A code path is untested. Add a test; do not lower `coverageThreshold` in `jest.config.js`.

```bash
npm run test:coverage
open coverage/lcov-report/index.html
```

### Tests pass locally, fail in CI

Almost always environment leakage. The suite must not depend on `.env`, the network, or a fixed
port. Run as CI does:

```bash
NODE_ENV=test npx jest --ci --runInBand --coverage
```

---

## 3. Docker

### `exec format error` when running the container

Architecture mismatch. On Apple Silicon the host is `arm64`; EC2 `t3.micro` is `amd64`.

```bash
docker build --platform linux/amd64 -t production-cicd-devops-project:local .
```

### Container is `unhealthy` but `curl` works from the host

The app is bound to `127.0.0.1` instead of `0.0.0.0`. Inside a container, `127.0.0.1` is only
reachable from inside that container — the Docker health check runs in the same namespace, but
published ports will not work.

```bash
docker exec <c> env | grep HOST      # must be 0.0.0.0
```

### `read-only file system` errors at runtime

Expected: the container runs with `--read-only`. If the app needs a writable path, add a `tmpfs` or a
volume — do not remove `--read-only`.

### `docker pull` returns `401 Unauthorized`

The Docker Hub repository is private. Either make it public (this project's design assumes a public
image, so no registry credentials live on the server) or `docker login` on the host.

---

## 4. CI

### `publish` job skipped on `main`

Check, in order:

1. Was the event a `push` (not a pull request)?
2. Did `lint-and-test` and `build-and-scan` both succeed?
3. Was `sonarqube` either successful or skipped? A *failed* gate blocks publishing — that is the
   intended behaviour.

### `::warning title=SonarQube not configured::`

`SONAR_ENABLED` is not `true`. Expected until SonarQube is set up (README §12). This is a warning,
never a success.

### `SonarQube scan: Project not found`

The `sonar.projectKey` / `sonar.organization` in `sonar-project.properties` must match the project
created in SonarQube Cloud. Import the repo first, then copy the exact keys.

### Trivy job fails with findings

That is the gate working. Read the artifact `security-reports`:

```bash
gh run download <run-id> -n security-reports
```

Then remediate: rebuild on a newer base (`apk upgrade` is already applied), or upgrade the
dependency. Do **not** add the CVE to `.trivyignore` unless all three conditions in that file's header
are met.

### `Error: Resource not accessible by integration` on SARIF upload

Code scanning needs GitHub Advanced Security, which is free only on public repositories. The workflow
already skips the upload on private repos (`github.event.repository.visibility == 'public'`) and the
blocking gate does not depend on it.

### YAML: `mapping values are not allowed here`

A `: ` inside an unquoted scalar. Wrap the value in a block scalar:

```yaml
- run: |
    docker image inspect --format 'Image size: {{.Size}} bytes' app:ci
```

---

## 5. Nginx

### `502 Bad Gateway`

Nginx is up, the upstream is not.

```bash
docker ps
docker logs --tail 50 notes-api-blue
systemctl status docker
curl -s 127.0.0.1:3000/health
```

### `503` with `{"error":{"code":"UPSTREAM_UNAVAILABLE"...}}`

This is the configured fallback (`error_page 502 503 504`), not a bug. It means Nginx could not reach
either slot. Fix the container, not Nginx.

### `nginx: [emerg] unknown "notes_api" upstream`

`/etc/nginx/notes-upstream.conf` is missing. `nginx/default.conf` includes it explicitly.

```bash
sudo install -m 0644 nginx/upstream.conf /etc/nginx/notes-upstream.conf
sudo nginx -t && sudo nginx -s reload
```

### `nginx: [emerg] duplicate default server for 0.0.0.0:80`

The distribution's default site is still enabled.

```bash
sudo mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo nginx -s reload
```

### Requests log `127.0.0.1` as the client IP

`proxy_set_header X-Real-IP` / `X-Forwarded-For` is missing, or `TRUST_PROXY` is 0. The app sets
`trust proxy` from `TRUST_PROXY` (default 1).

---

## 6. Deployment

### `[deploy] ERROR: Candidate did not become healthy`

The new container started but never answered `/health` correctly.

```bash
docker logs --tail 50 notes-api-green
```

Common causes: wrong `PORT`, app crashing on boot, `--expect-version` not matching the image's
`APP_VERSION` build argument.

Production traffic was **not** moved. State and upstream files are unchanged.

### `[deploy] ERROR: nginx -t rejected the new upstream configuration`

The generated file is malformed, usually because `UPSTREAM_FILE` points somewhere unwritable or a
stale file has wrong permissions.

```bash
ls -l /etc/nginx/notes-upstream.conf
cat /etc/nginx/notes-upstream.conf
```

### `[deploy] WARNING: Nginx revert failed - manual action required`

The post-switch verification failed *and* the automatic revert could not reload Nginx. Restore
manually:

```bash
cat /opt/notes-api/state/active_image      # what was live before
sudo sed -i 's/:[0-9]\{4\}/:3000/' /etc/nginx/notes-upstream.conf
sudo nginx -t && sudo nginx -s reload
```

### `No previous image recorded`

`/opt/notes-api/state/previous_image` is empty — this happens after the very first deployment. Use
`rollback.sh --image <ref>` with an explicit reference.

### `--image must include an explicit tag`

The script refuses to deploy an untagged reference (which would implicitly mean `latest`). Always
pass `repo:<sha>`.

---

## 7. AWS

### `An error occurred (AuthFailure)` / `Unable to locate credentials`

```bash
aws sts get-caller-identity
aws configure list
```

Do not paste long-lived access keys into the repository. Prefer an existing profile, an SSO session,
or an instance role.

### `Instance is not SSM-managed (status: None)`

```bash
# on the instance
systemctl status amazon-ssm-agent
sudo systemctl start amazon-ssm-agent

# from your machine
aws ssm describe-instance-information \
  --query 'InstanceInformationList[].[InstanceId,PingStatus]' --output table
```

Also confirm the instance profile has `AmazonSSMManagedInstanceCore` attached.

### SSH `Permission denied (publickey)` or timeout

The security group only allows your `/32` at the time `provision-aws.sh` ran. If your IP changed:

```bash
curl -s https://checkip.amazonaws.com
aws ec2 authorize-security-group-ingress --group-id <sg> \
  --protocol tcp --port 22 --cidr "$(curl -s https://checkip.amazonaws.com)/32"
```

Better: use SSM Session Manager instead and close port 22 entirely.

### `InvalidParameterValue: Invalid instance type`

Not every type is available in every AZ. Try `t3.small`, or a different region/subnet:

```bash
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters Name=instance-type,Values=t3.micro --region us-east-1
```

### Unexpected bill

```bash
aws ce get-cost-and-usage --time-period Start=2026-10-01,End=2026-10-31 \
  --granularity DAILY --metrics UnblendedCost
```

Remember: stopping an instance does not stop EBS or public-IPv4 charges.

---

## 8. Health check script

| Exit | Meaning |
| --- | --- |
| `0` | All assertions passed |
| `1` | A check failed (see the `[FAIL]` lines) |
| `2` | Bad usage or missing dependency |

```bash
./scripts/health-check.sh --url http://<host> --expect-version 1.0.0 --retries 12 --interval 5 --verbose
```
