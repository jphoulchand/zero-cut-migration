import boto3
import ipaddress

# Configuration
REGION = 'eu-west-1' # Change this to your region
BASE_NET = ipaddress.IPv4Network('10.0.0.0/8')
PREFIX = 16

def get_used_cidrs(region):
    ec2 = boto3.client('ec2', region_name=region)
    vpcs = ec2.describe_vpcs()['Vpcs']
    return [ipaddress.IPv4Network(vpc['CidrBlock']) for vpc in vpcs]

def find_first_available(base_net, prefix, used_cidrs):
    # Iterate over all possible /16 subnets within 10.0.0.0/8
    for subnet in base_net.subnets(new_prefix=prefix):
        collision = False
        for used in used_cidrs:
            # Check if the new subnet overlaps with any existing VPC
            if subnet.overlaps(used):
                collision = True
                break
        if not collision:
            return subnet
    return None

used = get_used_cidrs(REGION)
available = find_first_available(BASE_NET, PREFIX, used)

if available:
    print(f"✅ First available /16 in {REGION}: {available}")
else:
    print("❌ No available /16 blocks found in 10.0.0.0/8")


