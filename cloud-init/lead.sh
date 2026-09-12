#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/techsprint-lead-init.log) 2>&1
hostnamectl set-hostname __HOSTNAME__
