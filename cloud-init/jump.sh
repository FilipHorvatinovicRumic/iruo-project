#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/techsprint-jump-init.log) 2>&1
printf 'net.ipv4.ip_forward = 1\n' >/etc/sysctl.d/99-techsprint-forward.conf
sysctl --system
for i in $(seq 1 30); do
  if dnf -y install iptables-services curl; then
    break
  fi
  sleep 10
done
systemctl enable --now iptables
iptables -t nat -C POSTROUTING -s 10.0.0.0/8 -o eth0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s 10.0.0.0/8 -o eth0 -j MASQUERADE
iptables -C FORWARD -s 10.0.0.0/8 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.0.0.0/8 -j ACCEPT
iptables -C FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -d 10.0.0.0/8 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables-save >/etc/sysconfig/iptables
systemctl restart iptables
