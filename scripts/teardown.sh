#!/usr/bin/env bash
set -euo pipefail

echo "==> ECS Preview Teardown (PR #$PR)"

HOST="pr-${PR}.${DOMAIN}"
NAME="${SERVICE_PREFIX}${PR}"

# 1) Scale down and delete service
aws ecs update-service --cluster "$CLUSTER_NAME" --service "$NAME" --desired-count 0 >/dev/null 2>&1 || true
aws ecs delete-service --cluster "$CLUSTER_NAME" --service "$NAME" --force >/dev/null 2>&1 || true

# 2) Delete ALB rules
# Backend rule (host + path)
RULE_BE=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query "Rules[?contains(Conditions[?Field=='host-header'].Values[][], '${HOST}') && contains(Conditions[?Field=='path-pattern'].Values[][], '/api/*')].RuleArn" --output text)
[[ -n "$RULE_BE" && "$RULE_BE" != "None" ]] && aws elbv2 delete-rule --rule-arn "$RULE_BE" || true

# Frontend rule (host only)
RULE_FE=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query "Rules[?contains(Conditions[?Field=='host-header'].Values[][], '${HOST}') && length(Conditions)==1].RuleArn" --output text)
[[ -n "$RULE_FE" && "$RULE_FE" != "None" ]] && aws elbv2 delete-rule --rule-arn "$RULE_FE" || true

# 3) Delete TGs
for SFX in fe be; do
  TG=$(aws elbv2 describe-target-groups --names "${NAME}-${SFX}" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
  [[ -n "$TG" && "$TG" != "None" ]] && aws elbv2 delete-target-group --target-group-arn "$TG" || true
done

# 4) Delete DNS record
ALB_ARN=$(aws elbv2 describe-listeners --listener-arns "$LISTENER_ARN" --query "Listeners[0].LoadBalancerArn" --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query "LoadBalancers[0].DNSName" --output text)
cat > del.json <<EOF
{"Comment":"Delete ${HOST}","Changes":[{"Action":"DELETE","ResourceRecordSet":{"Name":"${HOST}","Type":"CNAME","TTL":60,"ResourceRecords":[{"Value":"${ALB_DNS}"}]}}]}
EOF
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --change-batch file://del.json >/dev/null 2>&1 || true

echo "Teardown completed for ${HOST}"
