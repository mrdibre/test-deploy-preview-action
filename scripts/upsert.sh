#!/usr/bin/env bash
set -euo pipefail

echo "==> ECS Preview Upsert (PR #$PR) in $AWS_REGION"

HOST="pr-${PR}.${DOMAIN}"
NAME="${SERVICE_PREFIX}${PR}"
TD_FAMILY="$NAME"

# 0) Resolve VPC/subnets if not provided
if [[ -z "${SUBNET_IDS:-}" ]]; then
  echo "Auto-selecting default VPC public subnets…"
  VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query "Vpcs[0].VpcId" --output text)
  SUBNET_IDS=$(aws ec2 describe-subnets \
    --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
    --query "Subnets[].SubnetId" --output text | tr '\t' ',')
fi

SG_ARG=""
if [[ -n "${SECURITY_GROUP_IDS:-}" ]]; then
  SG_ARG="securityGroups=[${SECURITY_GROUP_IDS}]"
else
  SG_ARG="securityGroups=[]"
fi

# 1) Build and push images
REGISTRY="$(aws ecr describe-registry --query 'registryId' --output text).dkr.ecr.${AWS_REGION}.amazonaws.com"
FE_TAG="pr-${PR}-fe-${GIT_SHA}"
BE_TAG="pr-${PR}-be-${GIT_SHA}"

echo "Building FE image $REGISTRY/${ECR_REPO_FE}:$FE_TAG"
docker build -f "$DOCKERFILE_FE" -t "$REGISTRY/${ECR_REPO_FE}:$FE_TAG" .
docker push "$REGISTRY/${ECR_REPO_FE}:$FE_TAG"

echo "Building BE image $REGISTRY/${ECR_REPO_BE}:$BE_TAG"
docker build -f "$DOCKERFILE_BE" -t "$REGISTRY/${ECR_REPO_BE}:$BE_TAG" .
docker push "$REGISTRY/${ECR_REPO_BE}:$BE_TAG"

FE_URI="$REGISTRY/${ECR_REPO_FE}:$FE_TAG"
BE_URI="$REGISTRY/${ECR_REPO_BE}:$BE_TAG"

# 2) Task Definition
cat > td.json <<EOF
{
  "family": "$TD_FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "${CPU}",
  "memory": "${MEMORY}",
  "executionRoleArn": "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/ecsTaskRole",
  "containerDefinitions": [
    {
      "name": "${FE_NAME}",
      "image": "${FE_URI}",
      "essential": true,
      "portMappings": [{"containerPort": ${FE_PORT}, "protocol": "tcp"}],
      "environment": ${FRONTEND_ENV_JSON},
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/preview",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "fe"
        }
      }
    },
    {
      "name": "${BE_NAME}",
      "image": "${BE_URI}",
      "essential": true,
      "portMappings": [{"containerPort": ${BE_PORT}, "protocol": "tcp"}],
      "environment": [{"name":"ENV","value":"preview"},{"name":"PR_NUMBER","value":"${PR}"}]$( [[ "$BACKEND_ENV_JSON" != "[]" ]] && echo ",${BACKEND_ENV_JSON}" ),
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/preview",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "be"
        }
      }
    }
  ]
}
EOF

aws ecs register-task-definition --cli-input-json file://td.json > td.out.json
TD_ARN=$(jq -r '.taskDefinition.taskDefinitionArn' td.out.json)
REV=$(jq -r '.taskDefinition.revision' td.out.json)
echo "Registered TD: $TD_ARN (rev $REV)"

# 3) Target Groups
VPC_ID=$(aws ec2 describe-subnets --subnet-ids "$(echo "$SUBNET_IDS" | tr ',' ' ')" --query "Subnets[0].VpcId" --output text)

FE_TG=$(aws elbv2 create-target-group --name ${NAME}-fe --protocol HTTP --port ${FE_PORT} --vpc-id $VPC_ID --target-type ip --health-check-path / --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || aws elbv2 describe-target-groups --names ${NAME}-fe --query "TargetGroups[0].TargetGroupArn" --output text)
BE_TG=$(aws elbv2 create-target-group --name ${NAME}-be --protocol HTTP --port ${BE_PORT} --vpc-id $VPC_ID --target-type ip --health-check-path /healthz --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || aws elbv2 describe-target-groups --names ${NAME}-be --query "TargetGroups[0].TargetGroupArn" --output text)
echo "FE_TG=$FE_TG"
echo "BE_TG=$BE_TG"

# 4) Service create/update
SVC_ARN=$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$NAME" --query "services[0].serviceArn" --output text 2>/dev/null || true)
if [[ "$SVC_ARN" == "None" || -z "$SVC_ARN" ]]; then
  echo "Creating ECS service $NAME"
  aws ecs create-service \
    --cluster "$CLUSTER_NAME" \
    --service-name "$NAME" \
    --task-definition "${TD_FAMILY}:${REV}" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[${SUBNET_IDS}],${SG_ARG},assignPublicIp=${ASSIGN_PUBLIC_IP}}" \
    --load-balancers "targetGroupArn=${FE_TG},containerName=${FE_NAME},containerPort=${FE_PORT}" \
                     "targetGroupArn=${BE_TG},containerName=${BE_NAME},containerPort=${BE_PORT}"
else
  echo "Updating ECS service $NAME"
  aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$NAME" \
    --task-definition "${TD_FAMILY}:${REV}" \
    --desired-count 1
fi

# 5) ALB rules
PRIORITY_FE=$((20000 + PR))
PRIORITY_BE=$((21000 + PR))

# - Backend rule: host + /api/*
BE_EXIST=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query "Rules[?contains(Conditions[?Field=='host-header'].Values[][], '${HOST}') && contains(Conditions[?Field=='path-pattern'].Values[][], '${API_PREFIX}')].RuleArn" --output text)
if [[ -n "$BE_EXIST" && "$BE_EXIST" != "None" ]]; then
  aws elbv2 delete-rule --rule-arn "$BE_EXIST" || true
fi
aws elbv2 create-rule --listener-arn "$LISTENER_ARN" \
  --priority "$PRIORITY_BE" \
  --conditions Field=host-header,Values="$HOST" Field=path-pattern,Values="$API_PREFIX" \
  --actions Type=forward,TargetGroupArn="$BE_TG" >/dev/null

# - Frontend rule: host (default /)
FE_EXIST=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query "Rules[?contains(Conditions[?Field=='host-header'].Values[][], '${HOST}) && length(Conditions)==1].RuleArn" --output text)
if [[ -n "$FE_EXIST" && "$FE_EXIST" != "None" ]]; then
  aws elbv2 delete-rule --rule-arn "$FE_EXIST" || true
fi
aws elbv2 create-rule --listener-arn "$LISTENER_ARN" \
  --priority "$PRIORITY_FE" \
  --conditions Field=host-header,Values="$HOST" \
  --actions Type=forward,TargetGroupArn="$FE_TG" >/dev/null

# 6) DNS (CNAME pr-<PR> -> ALB DNS)
ALB_ARN=$(aws elbv2 describe-listeners --listener-arns "$LISTENER_ARN" --query "Listeners[0].LoadBalancerArn" --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query "LoadBalancers[0].DNSName" --output text)
cat > rr.json <<EOF
{"Comment":"PR ${PR} preview","Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"${HOST}","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"${ALB_DNS}"}]}}]}
EOF
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch file://rr.json >/dev/null

echo "::notice title=Preview URL::https://${HOST}"
