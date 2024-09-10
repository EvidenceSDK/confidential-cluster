#!/bin/bash
#
# Copyright (c) 2024 Intel Corporation
# 
# SPDX-License-Identifier: Apache-2.0
# 

#set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

http_proxy=${http_proxy:-}
https_proxy=${https_proxy:-}
no_proxy=${no_proxy:-}

pod_network_cidr=${pod_network_cidr:-"10.244.0.0/16"}
service_cidr=${service_cidr:-"10.96.0.0/12"}
cni_project=${cni_project:-"calico"}
local_ip_address=""

init_cluster() {
	if [ -d "$HOME/.kube" ]; then
        	rm -rf "$HOME/.kube"
    	fi

	sudo bash -c 'modprobe br_netfilter'
	sudo bash -c 'modprobe overlay'
	sudo bash -c 'swapoff -a'

	sudo systemctl stop apparmor
	sudo  systemctl disable apparmor

	# initialize cluster
	sudo -E kubeadm init --ignore-preflight-errors=all --config kubeadm-config.yaml

	mkdir -p "${HOME}/.kube"
	sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
        sudo chown $(id -u):$(id -g) $HOME/.kube/config

	# taint master node:
	kubectl taint nodes --all node-role.kubernetes.io/control-plane-
}

install_cni() {

	if [[ $cni_project == "calico" ]]; then
		calico_url="https://projectcalico.docs.tigera.io/manifests/calico.yaml"
		kubectl apply -f $calico_url
	else
		flannel_url="https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"
		kubectl apply -f $flannel_url
	fi
}

find_local_ip_addr() {
	# Find the network interface name starting with "enp" or "eth"
	interface=$(ip -o link show | awk -F': ' '/^2: enp|^2: eth/ {print $2}')
	if [ ! -z "$interface" ]; then
		# Get the IP address of the found interface
		local_ip_address=$(ip -o -4 addr show "$interface" | awk '{print $4}' | cut -d/ -f1)
	fi
}

# Set proxy with systemctl.
# This steps is required for kubeadm, even though the proxies are set in the systemd config files.
set_systemctl_proxy() {
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

        NO_PROXY="$NO_PROXY"
        no_proxy="$no_proxy"
        if [ -z "$NO_PROXY" ]; then
                NO_PROXY="$no_proxy"
        fi

        if [[ -z "$HTTPS_PROXY" ]] && [[ -z "$HTTP_PROXY" ]]; then
		return
	fi

	find_local_ip_addr
	if [ ! -z "$local_ip_address" ]; then
		# Check if IP address is already added to NO_PROXY
		if [[ ! "$NO_PROXY" =~ (^|,)"$local_ip_address"(,|$) ]]; then
			NO_PROXY="$NO_PROXY,${local_ip_address}"
		else
			echo "Local ip address already present in NO_PROXY"
		fi
	fi

	if [[ ! "$NO_PROXY" =~ (^|,)"$pod_network_cidr"(,|$) ]]; then
		NO_PROXY="$NO_PROXY,${pod_network_cidr}"
	fi

	if [[ ! "$NO_PROXY" =~ (^|,)"$service_cidr"(,|$) ]]; then
		NO_PROXY="$NO_PROXY,${service_cidr}"
	fi

	export NO_PROXY="$NO_PROXY"
	export no_proxy="$NO_PROXY"
	env | grep -i proxy

	if [[ -n $HTTP_PROXY ]] || [[ -n $HTTPS_PROXY ]] || [[ -n $NO_PROXY ]]; then
		sudo systemctl set-environment HTTP_PROXY="$HTTP_PROXY"
		sudo systemctl set-environment HTTPS_PROXY="$HTTPS_PROXY"
		sudo systemctl set-environment NO_PROXY="$NO_PROXY"
		sudo systemctl restart containerd.service 
        fi
}

main() {
	set_systemctl_proxy
	init_cluster
	install_cni
}

main $@ 
