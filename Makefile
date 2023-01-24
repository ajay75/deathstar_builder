SHELL:=/bin/bash
REQUIRED_BINARIES := kubectl cosign helm terraform kubectx kubecm ytt yq jq
WORKING_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
BOOTSTRAP_DIR := ${WORKING_DIR}/bootstrap
TERRAFORM_DIR := ${WORKING_DIR}/terraform
WORKLOAD_DIR := ${ROOT_DIR}/workloads
GITOPS_DIR := ${ROOT_DIR}/gitops

HARVESTER_CONTEXT="deathstar"
BASE_URL=sienarfleet.systems
GITEA_URL=git.$(BASE_URL)
GIT_ADMIN_PASSWORD="C4rb1De_S3cr4t"
CLOUDFLARE_TOKEN=""
CERT_MANAGER_VERSION=1.8.1
RANCHER_VERSION=2.7.0

# Carbide info
CARBIDE_USER="internal-tester-read"
CARBIDE_PASSWORD=""
IMAGES_FILE=""

# Registry info
REGISTRY_URL=harbor.$(BASE_URL)
REGISTRY_USER=admin
REGISTRY_PASSWORD=""

# Rancher on Harvester Info
RKE2_VIP=10.10.5.5
RANCHER_TARGET_NETWORK=services
RANCHER_URL=rancher.deathstar.$(BASE_URL)
RANCHER_HA_MODE=false
RANCHER_CP_CPU_COUNT=2
RANCHER_CP_MEMORY_SIZE="4Gi"
RANCHER_WORKER_COUNT=3
RANCHER_NODE_SIZE="40Gi"
RANCHER_HARVESTER_WORKER_CPU_COUNT=2
RANCHER_HARVESTER_WORKER_MEMORY_SIZE="8Gi"
RANCHER_REPLICAS=3
HARVESTER_RANCHER_CLUSTER_NAME=rancher-harvester
RKE2_IMAGE_NAME=ubuntu-rke2-airgap-harvester
HARVESTER_RANCHER_CERT_SECRET=rancher_cert.yaml

# gitops automation vars
WORKLOADS_KAPP_APP_NAME=workloads
WORKLOADS_NAMESPACE=default

check-tools: ## Check to make sure you have the right tools
	$(foreach exec,$(REQUIRED_BINARIES),\
		$(if $(shell which $(exec)),,$(error "'$(exec)' not found. It is a dependency for this Makefile")))
# certificate targets
# CloudDNS holder: kubectl create secret generic clouddns-dns01-solver-svc-acct --from-file=key.json
certs: check-tools # needs CLOUD_TOKEN_FILE set and LOCAL_CLUSTER_NAME for non-default contexts
	@printf "\n===>Making Certificates\n";
	@kubectx $(HARVESTER_CONTEXT)
	@helm install cert-manager ${BOOTSTRAP_DIR}/rancher/cert-manager-v1.8.1.tgz \
    --namespace cert-manager \
	--create-namespace \
	--set installCRDs=true || true
	@kubectl create secret generic clouddns-dns01-solver-svc-acct -n cert-manager --from-file=$(CLOUD_TOKEN_FILE) --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -f $(BOOTSTRAP_DIR)/certs/issuer-prod-clouddns.yaml --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create ns harbor --dry-run=client -o yaml | kubectl apply -f -
	@ytt -f $(BOOTSTRAP_DIR)/certs/cert-harbor.yaml -v base_url=$(BASE_URL) | kubectl apply -f -
	@kubectl create ns git --dry-run=client -o yaml | kubectl apply -f -
	@ytt -f $(BOOTSTRAP_DIR)/certs/cert-gitea.yaml -v base_url=$(BASE_URL) | kubectl apply -f -
	@ytt -f $(BOOTSTRAP_DIR)/certs/cert-rancherdeathstar.yaml -v base_url=$(BASE_URL) | kubectl apply -f -

certs-export: check-tools
	@printf "\n===>Exporting Certificates\n";
	@kubectx $(HARVESTER_CONTEXT)
	@kubectl get secret -n harbor harbor-prod-homelab-certificate -o yaml > harbor_cert.yaml
	@kubectl get secret -n git gitea-prod-homelab-certificate -o yaml > gitea_cert.yaml
	@kubectl get secret -n cattle-system tls-rancherdeathstar-ingress -o yaml | yq e '.metadata.name = "tls-rancher-ingress"' > rancherdeathstar_cert.yaml
certs-import: check-tools
	@printf "\n===>Importing Certificates\n";
	@kubectx $(HARVESTER_CONTEXT)
	@kubectl apply -f harbor_cert.yaml
	@kubectl apply -f gitea_cert.yaml

# registry targets
registry: check-tools
	@printf "\n===> Installing Registry\n";
	@kubectx $(HARVESTER_CONTEXT)
	@helm upgrade --install harbor ${BOOTSTRAP_DIR}/harbor/harbor-1.9.3.tgz \
	--version 1.9.3 -n harbor -f ${BOOTSTRAP_DIR}/harbor/values.yaml --create-namespace
registry-delete: check-tools
	@printf "\n===> Deleting Registry\n";
	@kubectx $(HARVESTER_CONTEXT)
	@helm delete harbor -n harbor

# airgap targets
pull-rancher: check-tools
	@printf "\n===>Pulling Rancher Images\n";
	@${BOOTSTRAP_DIR}/airgap_images/pull_carbide_rancher $(CARBIDE_USER) '$(CARBIDE_PASSWORD)'
	@printf "\nIf successful, your images will be available at /tmp/rancher-images.tar.gz and /tmp/cert-manager.tar.gz"
pull-misc: check-tools
	@printf "\n===>Pulling Misc Images\n";
	@${BOOTSTRAP_DIR}/airgap_images/pull_misc
push-images: check-tools
	@printf "\n===>Pushing Images to Harbor\n";
	@${BOOTSTRAP_DIR}/airgap_images/push_carbide $(REGISTRY_URL) $(REGISTRY_USER) '$(REGISTRY_PASSWORD)' $(IMAGES_FILE)

# git targets
git: check-tools
	@kubectx $(HARVESTER_CONTEXT)
	@helm install gitea $(BOOTSTRAP_DIR)/gitea/gitea-6.0.1.tgz \
	--namespace git \
	--set gitea.admin.password=$(GIT_ADMIN_PASSWORD) \
	--set gitea.admin.username=gitea \
	--set persistence.size=10Gi \
	--set postgresql.persistence.size=1Gi \
	--set gitea.config.server.ROOT_URL=https://$(GITEA_URL) \
	--set gitea.config.server.DOMAIN=$(GITEA_URL) \
	--set gitea.config.server.PROTOCOL=http \
	-f $(BOOTSTRAP_DIR)/gitea/values.yaml
git-delete: check-tools
	@kubectx $(HARVESTER_CONTEXT)
	@printf "\n===> Deleting Gitea\n";
	@helm delete gitea -n git

### terraform main targets
infra: check-tools
	@printf "\n=====> Terraforming Infra\n";
	@$(MAKE) _terraform COMPONENT=infra

jumpbox: check-tools
	@printf "\n====> Terraforming Jumpbox\n";
	@$(MAKE) _terraform COMPONENT=jumpbox

jumpbox-key: check-tools
	@printf "\n====> Grabbing generated SSH key\n";
	@$(MAKE) _terraform-value COMPONENT=jumpbox FIELD=".jumpbox_ssh_key.value"
jumpbox-destroy: check-tools
	@printf "\n====> Destroying Jumpbox\n";
	@$(MAKE) _terraform-destroy COMPONENT=jumpbox

rancher: check-tools  # state stored in Harvester K8S
	@printf "\n====> Terraforming RKE2 + Rancher\n";
	@kubecm delete $(HARVESTER_RANCHER_CLUSTER_NAME) || true
	@kubectx $(HARVESTER_CONTEXT)
	@$(MAKE) _terraform COMPONENT=rancher VARS='TF_VAR_rancher_server_dns="$(RANCHER_URL)" TF_VAR_master_vip="$(RKE2_VIP)" TF_VAR_registry_url="$(REGISTRY_URL)" TF_VAR_control_plane_cpu_count=$(RANCHER_CP_CPU_COUNT) TF_VAR_control_plane_memory_size=$(RANCHER_CP_MEMORY_SIZE) TF_VAR_worker_count=$(RANCHER_WORKER_COUNT) TF_VAR_control_plane_ha_mode=$(RANCHER_HA_MODE) TF_VAR_node_disk_size=$(RANCHER_NODE_SIZE) TF_VAR_worker_cpu_count=$(RANCHER_HARVESTER_WORKER_CPU_COUNT) TF_VAR_worker_memory_size=$(RANCHER_HARVESTER_WORKER_MEMORY_SIZE) TF_VAR_target_network_name=$(RANCHER_TARGET_NETWORK) TF_VAR_harvester_rke2_image_name=$(shell kubectl get virtualmachineimage -o yaml | yq -e '.items[]|select(.spec.displayName=="$(RKE2_IMAGE_NAME)")' - | yq -e '.metadata.name' -)'
	@cp ${TERRAFORM_DIR}/rancher/kube_config_server.yaml /tmp/$(HARVESTER_RANCHER_CLUSTER_NAME).yaml && kubecm add -c -f /tmp/$(HARVESTER_RANCHER_CLUSTER_NAME).yaml && rm /tmp/$(HARVESTER_RANCHER_CLUSTER_NAME).yaml
	@kubectl get secret -n cattle-system tls-rancherdeathstar-ingress -o yaml | yq e '.metadata.name = "tls-rancher-ingress"' > $(HARVESTER_RANCHER_CERT_SECRET)
	@kubectx $(HARVESTER_RANCHER_CLUSTER_NAME)
	@helm upgrade --install cert-manager -n cert-manager --create-namespace --set installCRDs=true --set image.repository=$(REGISTRY_URL)/jetstack/cert-manager-controller --set webhook.image.repository=$(REGISTRY_URL)/jetstack/cert-manager-webhook --set cainjector.image.repository=$(REGISTRY_URL)/jetstack/cert-manager-cainjector --set startupapicheck.image.repository=$(REGISTRY_URL)/jetstack/cert-manager-ctl $(BOOTSTRAP_DIR)/rancher/cert-manager-v$(CERT_MANAGER_VERSION).tgz
	@helm upgrade --install rancher -n cattle-system --create-namespace --set hostname=$(RANCHER_URL) --set replicas=$(RANCHER_REPLICAS) --set bootstrapPassword=admin --set rancherImage=$(REGISTRY_URL)/rancher/rancher --set systemDefaultRegistry=$(REGISTRY_URL) --set ingress.tls.source=secret $(BOOTSTRAP_DIR)/rancher/rancher-$(RANCHER_VERSION).tgz
	@kubectl apply -f $(HARVESTER_RANCHER_CERT_SECRET)
	@kubectx $(HARVESTER_CONTEXT)
rancher-destroy: check-tools
	@printf "\n====> Destroying RKE2 + Rancher\n";
	@kubectx $(HARVESTER_CONTEXT)
	@$(MAKE) _terraform-destroy COMPONENT=rancher VARS='TF_VAR_target_network_name=$(RANCHER_TARGET_NETWORK) TF_VAR_harvester_rke2_image_name=$(shell kubectl get virtualmachineimage -o yaml | yq -e '.items[]|select(.spec.displayName=="$(RKE2_IMAGE_NAME)")' - | yq -e '.metadata.name' -)'
	@kubecm delete $(HARVESTER_RANCHER_CLUSTER_NAME) || true

# gitops targets
workloads-check: check-tools
	@printf "\n===> Synchronizing Workloads with Fleet (dry-run)\n";
	@kubectx $(HARVESTER_RANCHER_CLUSTER_NAME)
	@ytt -f $(WORKLOAD_DIR) | kapp deploy -a $(WORKLOADS_KAPP_APP_NAME) -n $(WORKLOADS_NAMESPACE) -f - 
	@kubectx -

workloads-yes: check-tools
	@printf "\n===> Synchronizing Workloads with Fleet\n";
	@kubectx $(HARVESTER_RANCHER_CLUSTER_NAME)
	@ytt -f $(WORKLOAD_DIR) | kapp deploy -a $(WORKLOADS_KAPP_APP_NAME) -n $(WORKLOADS_NAMESPACE) -f - -y 
	@kubectx -

workloads-delete: check-tools
	@printf "\n===> Deleting Workloads with Fleet\n";
	@kubectx $(HARVESTER_RANCHER_CLUSTER_NAME)
	@kapp delete -a $(WORKLOADS_KAPP_APP_NAME) -n $(WORKLOADS_NAMESPACE)
	@kubectx -

status: check-tools
	@printf "\n===> Inspecting Running Workloads in Fleet\n";
	@kubectx $(LOCAL_CLUSTER_NAME)
	@kapp inspect -a $(WORKLOADS_KAPP_APP_NAME) -n $(WORKLOADS_NAMESPACE)
	@kubectx -

# terraform sub-targets (don't use directly)
_terraform: check-tools
	@$(VARS) terraform -chdir=${TERRAFORM_DIR}/$(COMPONENT) init
	@$(VARS) terraform -chdir=${TERRAFORM_DIR}/$(COMPONENT) apply
_terraform-init: check-tools
	@$(VARS) terraform -chdir=${TERRAFORM_DIR}/$(COMPONENT) init
_terraform-apply: check-tools
	@$(VARS) terraform -chdir=${TERRAFORM_DIR}/$(COMPONENT) apply
_terraform-value: check-tools
	@terraform -chdir=${TERRAFORM_DIR}/$(COMPONENT) output -json | jq -r '$(FIELD)'
_terraform-destroy: check-tools
	@$(VARS) terraform -chdir=${TERRAFORM_DIR}/$(COMPONENT) destroy