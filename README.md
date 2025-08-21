EC2 Instance Migration Script (Interactive)

This repository contains a Bash script, move-ec2-instance-interactive.sh, that helps migrate an Amazon EC2 instance from one Availability Zone (AZ) to another within the same AWS region.  AWS does not allow live migration of an EC2 instance between AZs; instead, the typical approach is to create an Amazon Machine Image (AMI) from the instance and then launch a new instance from that AMI in the target AZ ￼.  The interactive script encapsulates this process and guides the operator through selecting a destination AZ and subnet, performs the necessary operations using the AWS CLI, and preserves key configuration details such as tags, security groups, key pairs and IAM roles.

Features
	•	Interactive selection of target AZ and subnet – The script detects the instance’s current Availability Zone and VPC, enumerates other AZs with subnets in the same VPC, and presents a menu so you can select the destination.  It then lists the subnets in the chosen AZ with their names for easy selection.
	•	Automated migration workflow – It stops the source instance, creates an AMI from it, waits for the AMI to become available, launches a new instance in the selected AZ and subnet, and waits until the new instance is running.
	•	Preservation of configuration – The script reads and reuses the original instance’s type, key pair, security groups and IAM instance profile when launching the new instance.  After launch, it applies all existing tags (adding a new Name tag if none exists) to both the new instance and its EBS volumes using the AWS CLI.
	•	Elastic IP reassignment – If the source instance has an associated Elastic IP (EIP), the script disassociates it from the old instance and re-associates it with the new one using disassociate-address and associate-address ￼ ￼.
	•	Progress messages and validation – The script prints informative messages while waiting for long operations (stopping the instance, AMI creation, instance launch) so it does not appear stalled.  It validates the source instance ID and ensures that there are alternative AZs and subnets before proceeding.
	•	Non‑destructive – The old instance and AMI are not terminated or deregistered automatically.  You can verify the new instance before performing any cleanup.

Prerequisites
	•	AWS CLI configured – The script requires AWS CLI v2.  Ensure that the CLI is installed in your environment (AWS CloudShell includes it by default) and that your credentials are configured with permissions to perform EC2 actions such as DescribeInstances, StopInstances, CreateImage, RunInstances, DescribeVolumes, CreateTags, DisassociateAddress and AssociateAddress.
	•	EBS‑backed instance – The create-image command only supports creating AMIs from EBS‑backed instances ￼.  Instance store (ephemeral) volumes cannot be preserved; they are not included in the AMI and any data stored there will be lost.
	•	Same VPC & Region – The script only migrates within the same region and VPC.  Cross‑region migrations would require copying the AMI to another region.

Usage
	1.	Download and make the script executable
 chmod +x move-ec2-instance-new-az.sh

 	2.	Run the script and follow the prompts
  ./move-ec2-instance-new-az.sh

  The script will prompt you for the source instance ID, display a numbered list of alternative Availability Zones in the same VPC, and ask you to choose one.  It then lists the subnets in the chosen AZ and asks you to select the destination subnet.  Finally, it prompts you for a name for the new instance.

	3.	Migration process
	•	Stop source instance – The script stops the selected instance.  Stopping an EBS‑backed instance halts compute charges but you still pay for the underlying EBS volumes ￼.
	•	Create AMI – It calls create-image to produce a new AMI from the stopped instance without rebooting it ￼.  According to AWS documentation, if you customized your instance with additional EBS volumes beyond the root device, the AMI contains block‑device mapping information for those volumes and the new instance automatically launches with them ￼.
	•	Launch new instance – The script launches a new instance from the AMI using run-instances, specifying the destination AZ via the AvailabilityZone field in the placement structure ￼.  It uses the same instance type, key pair, security groups and IAM instance profile ￼.
	•	Apply tags – After the new instance is running, the script retrieves the IDs of all attached EBS volumes and uses create-tags to copy each tag (including values with spaces) from the source instance to the new instance and its volumes.  If the source instance has no Name tag, it adds one using the name you supplied.
	•	Reassign Elastic IP (if applicable) – If the old instance has an Elastic IP, the script disassociates it and re‑associates it with the new instance ￼ ￼.
	4.	Verify and clean up
After the script completes, verify that the new instance is functioning correctly.  When you are satisfied, you may optionally terminate the old instance and deregister the AMI along with its snapshots to avoid additional charges.

Example

$ chmod +x move-ec2-instance-interactive.sh
$ ./move-ec2-instance-interactive.sh
Enter the source EC2 instance ID to migrate: i-0123456789abcdef0
Source instance is in Availability Zone: us-east-1a (Region: us-east-1)

Available destination Availability Zones in the same VPC:
1) us-east-1b
2) us-east-1c
3) us-east-1d
4) us-east-1e
Choose a destination AZ (1-4): 3

Selected Availability Zone: us-east-1d

Available subnets in us-east-1d:
1) subnet-0abc1234 (Public-Subnet)
2) subnet-0def5678 (Private-Subnet)
Choose the number of the destination subnet: 2

Destination subnet chosen: subnet-0def5678 in us-east-1d
Enter a name for the new instance: my-instance-us-east-1d
Stopping source instance i-0123456789abcdef0 ...
Waiting for the instance to enter the stopped state (this may take a few minutes)...
Source instance is stopped. Gathering attributes...
Creating AMI i-0123456789abcdef0-migration-20250821...
AMI ami-0123456789abcdef0 is now available.
Launching new instance in us-east-1d (subnet subnet-0def5678) ...
New instance launched: i-0fedcba9876543210
Waiting for the new instance to enter the running state...
New instance is running.
Applying tags to new instance and its volumes...
Elastic IP reassigned to i-0fedcba9876543210 (if applicable)
Migration complete. New instance ID: i-0fedcba9876543210

Troubleshooting
	•	“Instance not found or you do not have permission” – Ensure the instance ID is correct and your AWS credentials have permission to describe and stop the instance.
	•	No alternative Availability Zones – If the script reports that no other AZs exist, your VPC may only have subnets in a single AZ.  Create subnets in additional AZs before migrating.
	•	Missing tags on the new instance – The script applies tags after the new instance is running.  If tags are still missing, ensure the source instance actually had tags (other than the Name tag) and that your credentials have permission to create tags.
	•	Instance store volumes – Data on instance store volumes cannot be preserved.  Only EBS volumes are copied into the AMI and recreated on the new instance ￼.

Contributing

Contributions are welcome!  If you encounter bugs or want to add features (such as cross‑region migration or improved error handling), feel free to open an issue or submit a pull request.

License

This script is provided under the MIT License.  See LICENSE for details.
