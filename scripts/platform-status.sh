#!/usr/bin/env bash
# Shows whether the Dev environment is running and what is costing money right now.
# Read-only: changes nothing.
#
# Usage:  bash scripts/platform-status.sh
set -uo pipefail

CLUSTER=platform-dev
REGION=${AWS_REGION:-ap-south-1}

count() { echo "$1" | wc -w; }

eks=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query cluster.status --output text 2>/dev/null || echo "none")
nat=$(aws ec2 describe-nat-gateways --region "$REGION" \
  --filter "Name=tag:Project,Values=aws-platform" "Name=state,Values=available,pending" \
  --query 'NatGateways[].NatGatewayId' --output text)
vpce=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
  --filters "Name=tag:Project,Values=aws-platform" "Name=vpc-endpoint-type,Values=Interface" \
  --query 'VpcEndpoints[].VpcEndpointId' --output text)
nodes=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
lbs=$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$CLUSTER" \
  --resource-type-filters elasticloadbalancing:loadbalancer \
  --query 'ResourceTagMappingList[].ResourceARN' --output text)
eips=$(aws ec2 describe-addresses --region "$REGION" \
  --filters "Name=tag:Project,Values=aws-platform" --query 'Addresses[].AllocationId' --output text)

printf '%-28s %s\n' "EKS cluster $CLUSTER" "$eks"
printf '%-28s %s\n' "EC2 nodes running"         "$(count "$nodes")"
printf '%-28s %s\n' "NAT Gateways"              "$(count "$nat")"
printf '%-28s %s\n' "Interface VPC endpoints"   "$(count "$vpce")"
printf '%-28s %s\n' "Load balancers"            "$(count "$lbs")"
printf '%-28s %s\n' "Elastic IPs"               "$(count "$eips")"

if [ "$eks" = "none" ] && [ "$(count "$nat$nodes$lbs$vpce$eips")" -eq 0 ]; then
  echo; echo "STOPPED: only the state bucket and bootstrap key remain (a few cents per day)."
else
  echo; echo "RUNNING: costs accrue. Stop with: bash scripts/platform-stop.sh"
fi
