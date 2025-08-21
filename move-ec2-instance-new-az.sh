#!/bin/bash
# Interactive script to migrate an EC2 instance to another Availability Zone within the same region using AWS CLI.
#
# This script prompts for the source instance ID, automatically detects the current
# availability zone and VPC, shows a menu of other Availability Zones that have
# subnets in the same VPC, then lists the subnets in the chosen zone so the
# operator can select one.  It then performs the migration: stops the instance,
# creates an AMI, launches a new instance with the same tags, key pair, security
# groups and IAM role, and reassigns the Elastic IP if present.
#
# References:
# - Instances cannot be directly moved between availability zones; you must create an AMI and launch a new instance【886270743640741†L150-L156】.
# - The create-image CLI command creates an AMI from a running or stopped instance【463845269148344†L51-L57】.
# - The run-instances command allows specifying an availability zone via the placement structure【712455210151652†L1010-L1019】 and an instance profile【819964191722649†L1191-L1212】.
# - Elastic IPs can be disassociated and reassociated using the disassociate-address and associate-address commands【799884098330715†L51-L59】【467979053508514†L49-L63】.

set -euo pipefail

# Prompt for the source instance ID
read -rp "Enter the source EC2 instance ID to migrate: " SOURCE_INSTANCE_ID

# Verify that the instance exists
if ! aws ec2 describe-instances --instance-ids "$SOURCE_INSTANCE_ID" >/dev/null 2>&1; then
  echo "Error: Instance $SOURCE_INSTANCE_ID not found or you do not have permission to describe it."
  exit 1
fi

# Retrieve current placement and VPC ID
CURRENT_AZ=$(aws ec2 describe-instances --instance-ids "$SOURCE_INSTANCE_ID" --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)
VPC_ID=$(aws ec2 describe-instances --instance-ids "$SOURCE_INSTANCE_ID" --query 'Reservations[0].Instances[0].VpcId' --output text)
REGION=${CURRENT_AZ::-1} # Region is AZ minus the last character

echo "Source instance is in Availability Zone: $CURRENT_AZ (Region: $REGION)"

# Enumerate availability zones that have subnets in the same VPC, excluding the current AZ
mapfile -t AZ_LIST < <(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[*].AvailabilityZone' --output text | tr '\t' '\n' | sort -u | grep -v "^$CURRENT_AZ$")

if [ ${#AZ_LIST[@]} -eq 0 ]; then
  echo "No alternative Availability Zones found in VPC $VPC_ID."
  exit 1
fi

echo
echo "Available destination Availability Zones in the same VPC:"
select DEST_AZ in "${AZ_LIST[@]}"; do
  if [ -n "$DEST_AZ" ]; then
    break
  fi
  echo "Invalid selection; try again."
done

echo
echo "Selected Availability Zone: $DEST_AZ"

# List subnets in the selected AZ with their Name tags for user selection
mapfile -t SUBNET_INFO < <(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$DEST_AZ" \
  --query 'Subnets[*].[SubnetId, Tags[?Key==`Name`].Value | [0]]' --output text)

if [ ${#SUBNET_INFO[@]} -eq 0 ]; then
  echo "No subnets found in $DEST_AZ for VPC $VPC_ID."
  exit 1
fi

echo
echo "Available subnets in $DEST_AZ:"
INDEX=1
declare -A SUBNET_MAP
for LINE in "${SUBNET_INFO[@]}"; do
  SUBNET_ID=$(echo "$LINE" | awk '{print $1}')
  SUBNET_NAME=$(echo "$LINE" | awk '{print $2}')
  echo "$INDEX) $SUBNET_ID ($SUBNET_NAME)"
  SUBNET_MAP[$INDEX]="$SUBNET_ID"
  INDEX=$((INDEX+1))
done

read -rp "Choose the number of the destination subnet: " SUBNET_CHOICE

DEST_SUBNET_ID=${SUBNET_MAP[$SUBNET_CHOICE]:-}

if [ -z "$DEST_SUBNET_ID" ]; then
  echo "Invalid subnet selection."
  exit 1
fi

echo
echo "Destination subnet chosen: $DEST_SUBNET_ID in $DEST_AZ"

# Prompt for new instance name
read -rp "Enter a name for the new instance: " NEW_INSTANCE_NAME

# Stop the source instance
echo "Stopping source instance $SOURCE_INSTANCE_ID ..."
aws ec2 stop-instances --instance-ids "$SOURCE_INSTANCE_ID" --no-cli-pager
echo "Waiting for the instance to enter the stopped state (this may take a few minutes)..."
aws ec2 wait instance-stopped --instance-ids "$SOURCE_INSTANCE_ID"
echo "Source instance is stopped. Gathering attributes..."

# Gather attributes: instance type, key name, security groups and IAM profile
INSTANCE_TYPE=$(aws ec2 describe-instances --instance-ids "$SOURCE_INSTANCE_ID" --query 'Reservations[0].Instances[0].InstanceType' --output text)
KEY_NAME=$(aws ec2 describe-instances --instance-ids "$SOURCE_INSTANCE_ID" --query 'Reservations[0].Instances[0].KeyName' --output text)
SECURITY_GROUPS=$(aws ec2 describe-instances --instance-ids "$SOURCE_INSTANCE_ID" --query 'Reservations[0].Instances[0].SecurityGroups[*].GroupId' --output text)
INSTANCE_PROFILE_ARN=$(aws ec2 describe-instances --instance-ids "$SOURCE_INSTANCE_ID" --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text || true)

# Create an AMI
AMI_NAME="${SOURCE_INSTANCE_ID}-migration-$(date +%Y%m%d%H%M%S)"
echo "Creating AMI $AMI_NAME ..."
AMI_ID=$(aws ec2 create-image --instance-id "$SOURCE_INSTANCE_ID" --name "$AMI_NAME" --no-reboot \
  --query 'ImageId' --output text)
echo "AMI request submitted (ID: $AMI_ID). Waiting for the AMI to become available..."
aws ec2 wait image-available --image-ids "$AMI_ID"
echo "AMI $AMI_ID is now available."

# Build tag list from source instance
readarray -t TAG_KV <<< "$(aws ec2 describe-tags --filters "Name=resource-id,Values=$SOURCE_INSTANCE_ID" \
    --query 'Tags[*].[Key,Value]' --output text)"
# Build an array of tag arguments for later use with create-tags.  Using an
# array preserves spaces in tag values, as each element will be quoted
# individually when passed to the AWS CLI.  Each entry will take the form
# Key=<key>,Value=<value>.
TAG_ARGS=()
for TAG in "${TAG_KV[@]}"; do
  # Split the tab-delimited key/value pair.  Use cut to preserve spaces in values.
  KEY=$(echo "$TAG" | cut -f1)
  VALUE=$(echo "$TAG" | cut -f2-)
  # Append the tag argument without quotes; quoting will be applied when
  # passing the array to the CLI.
  TAG_ARGS+=("Key=${KEY},Value=${VALUE}")
done
# If no Name tag exists on the source instance, add one using the new instance name.
if [[ ${#TAG_ARGS[@]} -eq 0 ]] || [[ ! " ${TAG_ARGS[*]} " =~ "Key=Name," ]]; then
  TAG_ARGS+=("Key=Name,Value=${NEW_INSTANCE_NAME}")
fi

# Clean up any legacy variables from previous revisions to avoid confusion.
unset TAG_LIST TAG_SPEC_INSTANCE TAG_SPEC_VOLUME

# Build IAM option array
IAM_OPTION=()
if [[ -n "$INSTANCE_PROFILE_ARN" && "$INSTANCE_PROFILE_ARN" != "None" ]]; then
  IAM_OPTION=(--iam-instance-profile Arn=$INSTANCE_PROFILE_ARN)
fi

# Launch the new instance
echo "Launching new instance in $DEST_AZ (subnet $DEST_SUBNET_ID) ..."
NEW_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --security-group-ids $SECURITY_GROUPS \
  --subnet-id "$DEST_SUBNET_ID" \
  --placement AvailabilityZone="$DEST_AZ" \
  "${IAM_OPTION[@]}" \
  --query 'Instances[0].InstanceId' --output text)

echo "New instance launched: $NEW_INSTANCE_ID"

echo "Waiting for the new instance to enter the running state..."
aws ec2 wait instance-running --instance-ids "$NEW_INSTANCE_ID"
echo "New instance is running."

# Apply tags to the new instance and its volumes.  We first gather all volume
# IDs attached to the new instance, then call create-tags on both the instance
# and its volumes.  Passing each tag as a separate quoted argument preserves
# any spaces in tag values.  The --resources parameter accepts multiple
# resources (instance ID and volume IDs).
VOLUME_IDS=$(aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$NEW_INSTANCE_ID" \
  --query 'Volumes[*].VolumeId' --output text)
if [[ -n "$VOLUME_IDS" ]]; then
  echo "Applying tags to new instance and its volumes..."
  aws ec2 create-tags --resources "$NEW_INSTANCE_ID" $VOLUME_IDS --tags "${TAG_ARGS[@]}"
else
  echo "Applying tags to new instance..."
  aws ec2 create-tags --resources "$NEW_INSTANCE_ID" --tags "${TAG_ARGS[@]}"
fi

# Reassign Elastic IP if present
ALLOCATION_ID=$(aws ec2 describe-addresses --filters "Name=instance-id,Values=$SOURCE_INSTANCE_ID" --query 'Addresses[0].AllocationId' --output text || true)
ASSOCIATION_ID=$(aws ec2 describe-addresses --filters "Name=instance-id,Values=$SOURCE_INSTANCE_ID" --query 'Addresses[0].AssociationId' --output text || true)
if [[ "$ALLOCATION_ID" != "None" && -n "$ALLOCATION_ID" ]]; then
  echo "Reassigning Elastic IP allocation $ALLOCATION_ID ..."
  aws ec2 disassociate-address --association-id "$ASSOCIATION_ID" --no-cli-pager
  aws ec2 associate-address --allocation-id "$ALLOCATION_ID" --instance-id "$NEW_INSTANCE_ID" --no-cli-pager
  echo "Elastic IP reassigned to $NEW_INSTANCE_ID"
fi

echo "Migration complete. New instance ID: $NEW_INSTANCE_ID"
# Note: cleanup commands (terminate old instance, deregister AMI) are not executed automatically.
