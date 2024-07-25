#!/bin/bash
#
# Copyright (c) 2024 Intel Corporation
# 
# SPDX-License-Identifier: Apache-2.0
# 

set -e

http_proxy=${http_proxy:-}
https_proxy=${https_proxy:-}
no_proxy=${no_proxy:-}

function setup_proxy {
	cat <<-EOF | tee -a "/etc/environment"
http_proxy="${http_proxy}"
https_proxy="${https_proxy}"
no_proxy="${no_proxy}"
HTTP_PROXY="${http_proxy}"
HTTPS_PROXY="${https_proxy}"
NO_PROXY="${no_proxy}"
EOF


	cat <<-EOF | tee -a "/etc/profile.d/myenvvar.sh"
export http_proxy="${http_proxy}"
export https_proxy="${https_proxy}"
export no_proxy="${no_proxy}"
EOF

	systemctl set-environment http_proxy="${http_proxy}"
	systemctl set-environment https_proxy="${https_proxy}"
	systemctl set-environment no_proxy="${no_proxy}"
}

function install_docker {
	# install GPG key
	install -m 0755 -d /etc/apt/keyrings
	rm -f /etc/apt/keyrings/docker.gpg
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
	chmod a+r /etc/apt/keyrings/docker.gpg

	# install repo
	echo \
	"deb [arch=\"$(dpkg --print-architecture)\" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
	$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
	tee /etc/apt/sources.list.d/docker.list > /dev/null
	apt update > /dev/null

	# install docker
	apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	systemctl enable docker

	add_docker_proxy_for_builds
	
	# Add proxy for docker and containerd. This proxy is used in docker pull

	services=("containerd" "docker")
        add_systemd_service_proxy "${services[@]}"
}

function add_docker_proxy_for_builds() {
	mkdir -p /home/tdx/.docker
	cat <<-EOF | tee  "/home/tdx/.docker/config.json"
{
 "proxies": {
   "default": {
     "httpProxy": "${http_proxy}", 
     "httpsProxy": "${https_proxy}",
     "noProxy": "${no_proxy}"
   }
 }
}
EOF
}

function install_helm {
	# install repo
	curl -fsSL https://baltocdn.com/helm/signing.asc | gpg --dearmor | tee /usr/share/keyrings/helm.gpg > /dev/null
	echo \
	"deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" | \
	tee /etc/apt/sources.list.d/helm-stable-debian.list > /dev/null
	apt update > /dev/null

	# install helm
 	apt install -y helm
}


function install_pip {
	# install python3-pip
	apt install -y python3-pip 
}

function install_k3s {
	curl -o run_k3s.sh  https://get.k3s.io
	chmod +x ./run_k3s.sh

	#configure proxy
	local k3s_env_file="/etc/systemd/system/k3s.service.env"
	cat <<-EOF | tee -a $k3s_env_file
HTTP_PROXY="${http_proxy}"
HTTPS_PROXY="${https_proxy}"
NO_PROXY="${no_proxy}"
EOF

}

function install_k8s {
	apt -y clean
	apt purge kubeadm kubectl kubelet | true

	apt install -y wget apt-transport-https ca-certificates curl gnupg

	wget https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key
	gpg --no-default-keyring --keyring /tmp/k8s_keyring.gpg --import Release.key
	gpg --no-default-keyring --keyring /tmp/k8s_keyring.gpg --export > /tmp/k8s.gpg
	mv /tmp/k8s.gpg /etc/apt/trusted.gpg.d/

	echo 'deb https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list
	apt update
	apt install -y kubelet kubeadm kubectl

	# Packets traversing the bridge should be sent to iptables for processing
	echo br_netfilter | tee /etc/modules-load.d/k8s.conf
	echo "net.bridge.bridge-nf-call-ip6tables = 1" > /etc/sysctl.d/k8s.conf
	echo "net.bridge.bridge-nf-call-iptables = 1" >> /etc/sysctl.d/k8s.conf
	echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/k8s.conf
	sysctl --system

	# disable swap
	swapoff -a
	sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

	services=("kubelet")
	add_systemd_service_proxy "${services[@]}"
}

function add_systemd_service_proxy() {
	local components=("$@")
	 # Config proxy
	local HTTPS_PROXY="$HTTPS_PROXY"
	local https_proxy="$https_proxy"
	if [ -z "$HTTPS_PROXY" ]; then
		HTTPS_PROXY="$https_proxy"
	fi

	local HTTP_PROXY="$HTTP_PROXY"
	local http_proxy="$http_proxy"
	if [ -z "$HTTP_PROXY" ]; then
		HTTP_PROXY="$http_proxy"
	fi

	local NO_PROXY="$NO_PROXY"
	local no_proxy="$no_proxy"
	if [ -z "$NO_PROXY" ]; then
		NO_PROXY="$no_proxy"
	fi

	if [[ -n $HTTP_PROXY ]] || [[ -n $HTTPS_PROXY ]] || [[ -n $NO_PROXY ]]; then
		for component in "${components[@]}"; do
			echo "component: " "${component}"
			mkdir -p /etc/systemd/system/"${component}.service.d"/
			tee /etc/systemd/system/"${component}.service.d"/http-proxy.conf <<EOF
[Service]
Environment=\"HTTP_PROXY=${HTTP_PROXY}\"
Environment=\"HTTPS_PROXY=${HTTPS_PROXY}\"
Environment=\"NO_PROXY=${NO_PROXY}\"
EOF
			systemctl daemon-reload
			systemctl restart ${component}
		done
	fi
}

function disable_apparmor() {
	systemctl stop apparmor
	systemctl disable apparmor 
}

function configure_containerd() {
	mkdir -p /etc/containerd

	# This step is required as the default config installed with docker has cri plugin
	# disabled and does not work with kubernetes.
	containerd config default | tee /etc/containerd/config.toml

	# containerd that comes with docker uses pause 3.8 image, whereas kubernetes 1.31 
	# expects version 3.10
	sed -i -e 's/pause:3.8/pause:3.10/g' /etc/containerd/config.toml
}

function main {
	# Check if script is run as root
	if [[ $EUID -ne 0 ]]; then
		echo "Please run as root"
		exit 1
	fi

	setup_proxy
	
	# install pre-reqs
	apt update && apt install -y curl
	
	install_docker
	install_helm
	install_pip
	install_k8s
	disable_apparmor
	configure_containerd
	install_k3s
}

main $@
