#!/usr/bin/env bash
set -Eeuo pipefail

profile="${RACEGLYPH_AWS_PROFILE:-dhanush}"
region="${RACEGLYPH_AWS_REGION:-ap-south-1}"
stack_name="${RACEGLYPH_AWS_STACK:-raceglyph-pilot}"
domain="${RACEGLYPH_DOMAIN:-multiplayer.neutale.com}"
operations_email="${RACEGLYPH_OPERATIONS_EMAIL:-dhanush.sklm.2003@gmail.com}"
budget_usd="${RACEGLYPH_BUDGET_USD:-10}"
expected_account="${RACEGLYPH_AWS_ACCOUNT_ID:-}"
script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(unset CDPATH; cd -- "${script_dir}/../../.." && pwd)

if [[ -z "${expected_account}" || ! "${expected_account}" =~ ^[0-9]{12}$ ]]; then
  echo "Set RACEGLYPH_AWS_ACCOUNT_ID to the authorized 12-digit Dhanush account ID." >&2
  exit 2
fi
if [[ ! "${budget_usd}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "RACEGLYPH_BUDGET_USD must be a positive number." >&2
  exit 2
fi

actual_account=$(aws --profile "${profile}" --region "${region}" sts get-caller-identity --query Account --output text)
if [[ "${actual_account}" != "${expected_account}" ]]; then
  echo "Authenticated AWS account does not match the authorized Dhanush account." >&2
  exit 3
fi

cd "${project_dir}"
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Deployment requires a committed, clean Git tree." >&2
  exit 4
fi
commit=$(git rev-parse HEAD)
remote_commit=$(git ls-remote origin refs/heads/main | awk '{print $1}')
if [[ "${commit}" != "${remote_commit}" ]]; then
  echo "Local HEAD must match origin/main before cloud bootstrap." >&2
  exit 4
fi

vpc_id=$(aws --profile "${profile}" --region "${region}" ec2 describe-vpcs \
  --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
if [[ -z "${vpc_id}" || "${vpc_id}" == "None" ]]; then
  echo "The selected region has no default VPC." >&2
  exit 5
fi
subnet_id=$(aws --profile "${profile}" --region "${region}" ec2 describe-subnets \
  --filters Name=vpc-id,Values="${vpc_id}" Name=map-public-ip-on-launch,Values=true \
  --query 'sort_by(Subnets,&AvailabilityZone)[0].SubnetId' --output text)
if [[ -z "${subnet_id}" || "${subnet_id}" == "None" ]]; then
  echo "The default VPC has no public subnet." >&2
  exit 5
fi

aws --profile "${profile}" --region "${region}" cloudformation deploy \
  --stack-name "${stack_name}" \
  --template-file "${script_dir}/cloudformation.yaml" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    VpcId="${vpc_id}" \
    SubnetId="${subnet_id}" \
    RepositoryCommit="${commit}" \
    DomainName="${domain}" \
    OperationsEmail="${operations_email}" \
    BudgetLimitUsd="${budget_usd}"

aws --profile "${profile}" --region "${region}" cloudformation describe-stacks \
  --stack-name "${stack_name}" \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
  --output table
