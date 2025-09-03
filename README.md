# ECS Preview Environments (GitHub Action)

Create, update, and tear down ephemeral **ECS Fargate** preview environments with **frontend + backend** containers, **ALB host + /api/* routing**, and **Route53** DNS per pull request.

## Prereqs

- OIDC role for GitHub: `aws-actions/configure-aws-credentials@v4`
- Existing ALB (HTTPS 443) with ACM cert
- Route53 public hosted zone
- ECS Cluster
- ECR repositories for FE and BE
- CloudWatch log group `/ecs/preview` (or auto-create on first logs)

## Example workflow

```yaml
name: Preview Env

on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

jobs:
  upsert:
    if: github.event.action != 'closed'
    runs-on: ubuntu-latest
    steps:
      - name: Preview Upsert
        uses: your-org/ecs-preview-action@v1
        with:
          state: upsert
          aws-region: us-west-2
          role-to-assume: arn:aws:iam::111111111111:role/github-oidc-deployer

          cluster-name: backend
          alb-listener-https-arn: arn:aws:elasticloadbalancing:us-west-2:111111111111:listener/app/APP/ALBID/LISTENERID
          hosted-zone-id: Z123EXAMPLE
          domain: example.com
          service-prefix: preview-pr-

          ecr-repo-frontend: rendair/web-frontend
          ecr-repo-backend: rendair/web-backend
          frontend-dockerfile: ./frontend/Dockerfile
          backend-dockerfile: ./backend/Dockerfile

          frontend-container-name: web-frontend
          backend-container-name: web-backend
          frontend-port: 80
          backend-port: 80
          api-path-prefix: /api/*

          cpu: 512
          memory: 1024
          # Optional networking overrides:
          # subnet-ids: subnet-aaa,subnet-bbb,subnet-ccc
          # security-group-ids: sg-1234567890abcdef0
          assign-public-ip: ENABLED

          pr-number: ${{ github.event.pull_request.number }}
          git-sha: ${{ github.sha }}

          # Optional env injection (JSON arrays of {name,value})
          backend-env-json: >-
            [{"name":"ENV","value":"preview"},{"name":"FEATURE_FLAG","value":"true"}]
          frontend-env-json: >-
            [{"name":"PUBLIC_API_BASE","value":"https://pr-${{ github.event.pull_request.number }}.example.com/api"}]

  teardown:
    if: github.event.action == 'closed'
    runs-on: ubuntu-latest
    steps:
      - name: Preview Teardown
        uses: your-org/ecs-preview-action@v1
        with:
          state: teardown
          aws-region: us-west-2
          role-to-assume: arn:aws:iam::111111111111:role/github-oidc-deployer

          cluster-name: backend
          alb-listener-https-arn: arn:aws:elasticloadbalancing:us-west-2:111111111111:listener/app/APP/ALBID/LISTENERID
          hosted-zone-id: Z123EXAMPLE
          domain: example.com
          service-prefix: preview-pr-
          pr-number: ${{ github.event.pull_request.number }}
          git-sha: ${{ github.sha }}
