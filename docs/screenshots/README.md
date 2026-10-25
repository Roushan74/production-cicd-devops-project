# Screenshots

This directory is for screenshots of **real** systems only.

No image in this repository is illustrative, generated, mocked up, or reconstructed. If a screenshot
is not here, it is because the corresponding run has not been captured yet — the README says so
explicitly rather than showing a placeholder.

## What belongs here

| Filename | Content | Captured from |
| --- | --- | --- |
| `ci-pipeline-success.png` | All CI jobs green on `main` | GitHub Actions run page |
| `ci-trivy-gate-failure.png` | A build blocked by a HIGH finding | GitHub Actions run page |
| `sonar-quality-gate.png` | Quality gate passed | SonarQube project dashboard |
| `dockerhub-tags.png` | SHA tag + digest published | Docker Hub repository tags |
| `aws-ec2-instance.png` | Instance running, security group rules | AWS console |
| `nginx-access-log.png` | Live access log with real client IPs | EC2 host terminal |
| `public-health-endpoint.png` | `/health` served from the public IP | Browser / curl |
| `rollback-transcript.png` | Rollback to the previous image | EC2 host terminal |

## How to capture them honestly

1. Perform the run.
2. Capture the whole window, including the URL bar or terminal prompt, so the source is identifiable.
3. Do not crop out failing steps, warnings or timestamps.
4. Do not annotate numbers onto the image.
5. Add the file, then reference it from the README section it belongs to.

## Current status

The verification evidence available today is textual, not visual, and lives in:

- `docs/deployment.md` §6 — real `deploy.sh` / `rollback.sh` transcripts
- the README tables of verified checks

Screenshots for the CI run, SonarQube, Docker Hub and the AWS deployment will be added once those
integrations have actually been executed with the owner's credentials.
