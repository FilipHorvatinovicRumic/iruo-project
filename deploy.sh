#!/usr/bin/env bash
set -euo pipefail

CSV="${1:-}"
[[ -n "$CSV" && -f "$CSV" ]] || { echo "Usage: $0 users.csv"; exit 1; }

if [[ -f ./overcloudrc ]]; then
  source ./overcloudrc
elif [[ -f "$HOME/overcloudrc" ]]; then
  source "$HOME/overcloudrc"
else
  echo "ERROR: overcloudrc not found"
  exit 1
fi

export OS_IDENTITY_API_VERSION=3

MGMT_PROJECT="ts-management"
EXTERNAL_NETWORK="provider-datacentre"
APP_IMAGE="rhel8-web"
JUMP_IMAGE="rhel8"
APP_FLAVOR="ts-app-2c4g"
JUMP_FLAVOR="default"
VOLUME_TYPE="tripleo"
KEY_NAME="techsprint-key"
SSH_PRIVATE="$HOME/.ssh/techsprint_rsa"
SSH_PUBLIC="${SSH_PRIVATE}.pub"
USER_PASSWORD="${TS_USER_PASSWORD:-TechSprint!2026}"
MANILA_TYPE="ts-cephfs"
MGMT_NET="ts-mgmt-net"
MGMT_SUBNET="ts-mgmt-subnet"
JUMP_NET="ts-jump-net"
JUMP_SUBNET="ts-jump-subnet"
JUMP_ROUTER="ts-jump-router"
JUMP_SG="ts-jump-sg"
JUMP_SERVER="ts-devops-jump01"
JUMP_FIXED_IP="10.200.0.10"
JUMP_MGMT_IP="10.250.0.10"
ADMIN_USER="${OS_USERNAME:-admin}"

log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
exists() { "$@" >/dev/null 2>&1; }
osc() { openstack "$@"; }
osproj() { local project="$1"; shift; OS_PROJECT_NAME="$project" openstack "$@"; }
manproj() { local project="$1"; shift; OS_PROJECT_NAME="$project" manila "$@"; }


wait_lb() {
  local project="$1" lb="$2" status=""
  for _ in $(seq 1 90); do
    status="$(osproj "$project" loadbalancer show "$lb" -f value -c provisioning_status 2>/dev/null || true)"
    [[ "$status" == "ACTIVE" ]] && return 0
    if [[ "$status" == "ERROR" ]]; then
      echo "ERROR: Octavia load balancer $lb entered ERROR state"
      osproj "$project" loadbalancer show "$lb" || true
      return 1
    fi
    sleep 2
  done
  echo "ERROR: Timed out waiting for Octavia load balancer $lb; last status=$status"
  return 1
}

ensure_octavia() {
  local project="$1" slug="$2" mgmt_subnet_id="$3" vip="$4" app1_ip="$5" app2_ip="$6"
  local lb="ts-${slug}-lb"
  local listener="ts-${slug}-tcp80-listener"
  local pool="ts-${slug}-tcp80-pool"
  local member1="ts-${slug}-moodle01"
  local member2="ts-${slug}-moodle02"

  log "Ensuring Octavia OVN load balancer $lb"

  if ! exists osproj "$project" loadbalancer show "$lb"; then
    osproj "$project" loadbalancer create \
      --name "$lb" \
      --provider ovn \
      --vip-subnet-id "$mgmt_subnet_id" \
      --vip-address "$vip" \
      >/dev/null
  fi
  wait_lb "$project" "$lb"

  if ! exists osproj "$project" loadbalancer listener show "$listener"; then
    osproj "$project" loadbalancer listener create \
      --name "$listener" \
      --protocol TCP \
      --protocol-port 80 \
      "$lb" >/dev/null
  fi
  wait_lb "$project" "$lb"

  if ! exists osproj "$project" loadbalancer pool show "$pool"; then
    osproj "$project" loadbalancer pool create \
      --name "$pool" \
      --protocol TCP \
      --listener "$listener" \
      --lb-algorithm SOURCE_IP_PORT \
      >/dev/null
  fi
  wait_lb "$project" "$lb"

  if ! osproj "$project" loadbalancer member list "$pool" -f value -c name 2>/dev/null | grep -Fxq "$member1"; then
    osproj "$project" loadbalancer member create \
      --name "$member1" \
      --address "$app1_ip" \
      --subnet-id "$mgmt_subnet_id" \
      --protocol-port 80 \
      "$pool" >/dev/null
  fi
  wait_lb "$project" "$lb"

  if ! osproj "$project" loadbalancer member list "$pool" -f value -c name 2>/dev/null | grep -Fxq "$member2"; then
    osproj "$project" loadbalancer member create \
      --name "$member2" \
      --address "$app2_ip" \
      --subnet-id "$mgmt_subnet_id" \
      --protocol-port 80 \
      "$pool" >/dev/null
  fi
  wait_lb "$project" "$lb"
}

[[ -f "$SSH_PUBLIC" ]] || ssh-keygen -t rsa -b 4096 -N '' -f "$SSH_PRIVATE"

log "Validating OpenStack credentials"
osc token issue >/dev/null

log "Creating flavors and IAM roles"
exists osc flavor show "$APP_FLAVOR" || osc flavor create --ram 4096 --vcpus 2 --disk 0 "$APP_FLAVOR"
exists osc flavor show "$JUMP_FLAVOR" || osc flavor create --ram 1024 --vcpus 1 --disk 8 "$JUMP_FLAVOR"
exists osc role show developer || osc role create developer
exists osc role show devops_lead || osc role create devops_lead

log "Creating Manila CephFS share type"
if ! manila type-list | awk -F'|' '{gsub(/ /,"",$3); print $3}' | grep -qx "$MANILA_TYPE"; then
  manila type-create "$MANILA_TYPE" false
fi

log "Reading CSV and creating DevOps Lead identity"
LEAD_USER=""
while IFS=';' read -r firstname lastname role; do
  [[ "$firstname" == "ime" || -z "$firstname" ]] && continue
  username="$(printf '%s.%s' "$firstname" "$lastname" | tr '[:upper:]' '[:lower:]')"
  if [[ "$role" == "devops_lead" ]]; then
    LEAD_USER="$username"
    exists osc user show "$username" || osc user create --domain Default --password "$USER_PASSWORD" "$username"
  fi
done < "$CSV"
[[ -n "$LEAD_USER" ]] || { echo "ERROR: CSV requires one devops_lead"; exit 1; }

log "Creating central management project"
exists osc project show "$MGMT_PROJECT" || osc project create --domain Default --description "TechSprint central management and jump-host project" "$MGMT_PROJECT"
osc role add --project "$MGMT_PROJECT" --user "$ADMIN_USER" admin 2>/dev/null || true
osc role add --project "$MGMT_PROJECT" --user "$LEAD_USER" member 2>/dev/null || true
osc role add --project "$MGMT_PROJECT" --user "$LEAD_USER" devops_lead 2>/dev/null || true

log "Creating shared management network"
if ! exists osproj "$MGMT_PROJECT" network show "$MGMT_NET"; then
  osproj "$MGMT_PROJECT" network create --share "$MGMT_NET"
  osproj "$MGMT_PROJECT" network set --tag project=techsprint --tag environment=testing "$MGMT_NET" || true
fi
if ! exists osproj "$MGMT_PROJECT" subnet show "$MGMT_SUBNET"; then
  osproj "$MGMT_PROJECT" subnet create --network "$MGMT_NET" --subnet-range 10.250.0.0/24 --gateway none --dhcp "$MGMT_SUBNET"
fi
MGMT_NET_ID="$(osproj "$MGMT_PROJECT" network show "$MGMT_NET" -f value -c id)"
MGMT_SUBNET_ID="$(osproj "$MGMT_PROJECT" subnet show "$MGMT_SUBNET" -f value -c id)"

log "Creating central jump-host network"
exists osproj "$MGMT_PROJECT" network show "$JUMP_NET" || osproj "$MGMT_PROJECT" network create "$JUMP_NET"
exists osproj "$MGMT_PROJECT" subnet show "$JUMP_SUBNET" || osproj "$MGMT_PROJECT" subnet create --network "$JUMP_NET" --subnet-range 10.200.0.0/24 --gateway 10.200.0.1 --dns-nameserver 8.8.8.8 "$JUMP_SUBNET"
exists osproj "$MGMT_PROJECT" router show "$JUMP_ROUTER" || osproj "$MGMT_PROJECT" router create "$JUMP_ROUTER"
osproj "$MGMT_PROJECT" router set --external-gateway "$EXTERNAL_NETWORK" "$JUMP_ROUTER"
osproj "$MGMT_PROJECT" router add subnet "$JUMP_ROUTER" "$JUMP_SUBNET" 2>/dev/null || true
osproj "$MGMT_PROJECT" network set --tag project=techsprint --tag environment=testing "$JUMP_NET" || true
osproj "$MGMT_PROJECT" router set --tag project=techsprint --tag environment=testing "$JUMP_ROUTER" || true

if ! exists osproj "$MGMT_PROJECT" security group show "$JUMP_SG"; then
  osproj "$MGMT_PROJECT" security group create --description "TechSprint public jump host only" "$JUMP_SG"
  osproj "$MGMT_PROJECT" security group rule create --ingress --protocol tcp --dst-port 22 --remote-ip 0.0.0.0/0 "$JUMP_SG"
  osproj "$MGMT_PROJECT" security group rule create --ingress --protocol icmp --remote-ip 0.0.0.0/0 "$JUMP_SG"
fi

exists osproj "$MGMT_PROJECT" keypair show "$KEY_NAME" || osproj "$MGMT_PROJECT" keypair create --public-key "$SSH_PUBLIC" "$KEY_NAME" >/dev/null

if ! exists osproj "$MGMT_PROJECT" server show "$JUMP_SERVER"; then
  JUMP_PUBLIC_PORT="$(osproj "$MGMT_PROJECT" port create --network "$JUMP_NET" --fixed-ip subnet="$JUMP_SUBNET",ip-address="$JUMP_FIXED_IP" --security-group "$JUMP_SG" ts-jump-public-port -f value -c id)"
  JUMP_MGMT_PORT="$(osproj "$MGMT_PROJECT" port create --network "$MGMT_NET" --fixed-ip subnet="$MGMT_SUBNET",ip-address="$JUMP_MGMT_IP" --security-group "$JUMP_SG" ts-jump-mgmt-port -f value -c id)"
  osproj "$MGMT_PROJECT" server create --image "$JUMP_IMAGE" --flavor "$JUMP_FLAVOR" --key-name "$KEY_NAME" --nic port-id="$JUMP_PUBLIC_PORT" --nic port-id="$JUMP_MGMT_PORT" --wait "$JUMP_SERVER"
  osproj "$MGMT_PROJECT" server set --property project=techsprint --property environment=testing "$JUMP_SERVER"
fi

JUMP_PORT_ID="$(osproj "$MGMT_PROJECT" port list --server "$JUMP_SERVER" --network "$JUMP_NET" -f value -c ID | head -1)"
JUMP_FIP="$(osproj "$MGMT_PROJECT" floating ip list --port "$JUMP_PORT_ID" -f value -c 'Floating IP Address' | head -1 || true)"
if [[ -z "$JUMP_FIP" ]]; then
  JUMP_FIP="$(osproj "$MGMT_PROJECT" floating ip create "$EXTERNAL_NETWORK" -f value -c floating_ip_address)"
  osproj "$MGMT_PROJECT" server add floating ip "$JUMP_SERVER" "$JUMP_FIP"
fi

log "Validating Heat template"
osproj "$MGMT_PROJECT" orchestration template validate -t templates/developer.yaml \
  --parameter developer_slug=validation \
  --parameter private_cidr=10.20.99.0/24 \
  --parameter private_gateway=10.20.99.1 \
  --parameter mgmt_network="$MGMT_NET_ID" \
  --parameter mgmt_subnet="$MGMT_SUBNET_ID" \
  --parameter app1_mgmt_ip=10.250.0.241 \
  --parameter app2_mgmt_ip=10.250.0.242 \
  --parameter lb_vip=10.250.0.245 \
  --parameter external_network="$EXTERNAL_NETWORK" \
  --parameter image="$APP_IMAGE" \
  --parameter flavor="$APP_FLAVOR" \
  --parameter key_name="$KEY_NAME" \
  --parameter volume_type="$VOLUME_TYPE" >/dev/null

log "Creating developer projects and infrastructure"
DEV_INDEX=0
while IFS=';' read -r firstname lastname role; do
  [[ "$firstname" == "ime" || -z "$firstname" || "$role" != "developer" ]] && continue

  DEV_INDEX=$((DEV_INDEX + 1))
  username="$(printf '%s.%s' "$firstname" "$lastname" | tr '[:upper:]' '[:lower:]')"
  slug="$(printf '%s-%s' "$firstname" "$lastname" | tr '[:upper:]' '[:lower:]')"
  project="ts-${slug}"
  stack="ts-${slug}-stack"
  share="ts-${slug}-files"
  ceph_user="techsprint_${slug//-/_}"
  cidr="10.20.${DEV_INDEX}.0/24"
  gateway="10.20.${DEV_INDEX}.1"
  base=$((20 + DEV_INDEX * 10))
  app1_mgmt="10.250.0.$((base + 1))"
  app2_mgmt="10.250.0.$((base + 2))"
  lb_vip="10.250.0.$((base + 5))"

  log "Developer $DEV_INDEX: $username ($project)"

  exists osc project show "$project" || osc project create --domain Default --description "TechSprint testing environment for $username" "$project"
  exists osc user show "$username" || osc user create --domain Default --password "$USER_PASSWORD" "$username"

  osc role add --project "$project" --user "$username" member 2>/dev/null || true
  osc role add --project "$project" --user "$username" developer 2>/dev/null || true
  osc role add --project "$project" --user "$LEAD_USER" member 2>/dev/null || true
  osc role add --project "$project" --user "$LEAD_USER" devops_lead 2>/dev/null || true
  osc role add --project "$project" --user "$ADMIN_USER" admin 2>/dev/null || true

  exists osproj "$project" keypair show "$KEY_NAME" || osproj "$project" keypair create --public-key "$SSH_PUBLIC" "$KEY_NAME" >/dev/null

  if ! manproj "$project" list --name "$share" | grep -q "$share"; then
    manproj "$project" create CEPHFS 1 --share-type "$MANILA_TYPE" --name "$share" --metadata project=techsprint environment=testing owner="$slug"
  fi

  log "Waiting for Manila share $share"
  share_status=""
  for _ in $(seq 1 60); do
    share_status="$(manproj "$project" show "$share" | awk -F'|' '/ status /{gsub(/ /,"",$3); print $3; exit}')"
    [[ "$share_status" == "available" ]] && break
    [[ "$share_status" == "error" ]] && { echo "ERROR: Manila share $share entered error state"; manproj "$project" show "$share"; exit 1; }
    sleep 5
  done
  [[ "$share_status" == "available" ]] || { echo "ERROR: Manila share $share did not become available"; exit 1; }

  if ! manproj "$project" access-list "$share" --columns access_type,access_to 2>/dev/null | grep -q "$ceph_user"; then
    manproj "$project" access-allow "$share" cephx "$ceph_user" >/dev/null
  fi

  stack_status="$(osproj "$project" stack show "$stack" -f value -c stack_status 2>/dev/null || true)"
  if [[ "$stack_status" == *FAILED ]]; then
    log "Deleting failed Heat stack $stack"
    osproj "$project" stack delete --yes --wait "$stack"
    stack_status=""
  fi

  if [[ -z "$stack_status" ]]; then
    osproj "$project" stack create --wait -t templates/developer.yaml \
      --parameter developer_slug="$slug" \
      --parameter image="$APP_IMAGE" \
      --parameter flavor="$APP_FLAVOR" \
      --parameter key_name="$KEY_NAME" \
      --parameter external_network="$EXTERNAL_NETWORK" \
      --parameter private_cidr="$cidr" \
      --parameter private_gateway="$gateway" \
      --parameter mgmt_network="$MGMT_NET_ID" \
      --parameter mgmt_subnet="$MGMT_SUBNET_ID" \
      --parameter app1_mgmt_ip="$app1_mgmt" \
      --parameter app2_mgmt_ip="$app2_mgmt" \
      --parameter lb_vip="$lb_vip" \
      --parameter volume_type="$VOLUME_TYPE" \
      "$stack"
  else
    echo "Stack $stack status is $stack_status; leaving Heat resources unchanged."
  fi

  ensure_octavia "$project" "$slug" "$MGMT_SUBNET_ID" "$lb_vip" "$app1_mgmt" "$app2_mgmt"

done < "$CSV"

log "Deployment summary"
printf '%-26s %s\n' 'Management project:' "$MGMT_PROJECT"
printf '%-26s %s\n' 'Jump host:' "$JUMP_SERVER"
printf '%-26s %s\n' 'Jump floating IP:' "$JUMP_FIP"
printf '%-26s %s\n' 'Jump management IP:' "$JUMP_MGMT_IP"
printf '%-26s %s\n' 'DevOps lead:' "$LEAD_USER"
printf '%-26s %s\n' 'Developers:' "$DEV_INDEX"
echo

while IFS=';' read -r firstname lastname role; do
  [[ "$firstname" == "ime" || -z "$firstname" || "$role" != "developer" ]] && continue
  slug="$(printf '%s-%s' "$firstname" "$lastname" | tr '[:upper:]' '[:lower:]')"
  project="ts-${slug}"
  stack="ts-${slug}-stack"
  share="ts-${slug}-files"
  echo "=== $project ==="
  echo -n "LB VIP: "
  osproj "$project" stack output show "$stack" load_balancer_vip -f value -c output_value 2>/dev/null || true
  osproj "$project" server list
  osproj "$project" volume list
  manproj "$project" list --name "$share"
  manproj "$project" share-export-location-list "$share" 2>/dev/null || true
  manproj "$project" access-list "$share" 2>/dev/null || true
  osproj "$project" container list
  echo
done < "$CSV"

cat <<EOF2
NEXT VALIDATION
---------------
From workstation:
  ssh -A -i $SSH_PRIVATE cloud-user@$JUMP_FIP

From the jump host, test the application addresses/LB VIPs listed above with curl.
Lab user password: $USER_PASSWORD
EOF2
