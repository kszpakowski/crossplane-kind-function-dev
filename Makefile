GREEN := \033[0;32m
NC := \033[0m

CLUSTER_NAME := crossplane-local
CROSSPLANE_NAMESPACE := crossplane-system
REGISTRY_NAMESPACE := default
MANIFEST_DIR := manifests
CERT_NAME := oci-registry-tls
CONFIG_MAP_NAME := distribution-ca
CHART_NAME := crossplane
CHART_REPO_NAME := crossplane-stable
CHART_REPO_URL := https://charts.crossplane.io/stable
IMAGE_TAG := oci-registry.default.svc.cluster.local/crossplane-contrib/function-kcl:v0.11.4
LOCAL_IMAGE := localhost:5000/crossplane-contrib/function-kcl:v0.11.4

REQUIRED_TOOLS := kind kubectl helm openssl docker skopeo

.PHONY: all check-tools install create-cluster create-namespace generate-cert install-crossplane build-image push-image deploy-function cleanup

all: check-tools create-cluster create-namespace generate-cert install-crossplane build-image push-image deploy-function
	@echo "$(GREEN)✅ Setup complete!$(NC)"

check-tools:
	@echo "🔍 Checking required tools..."
	@for tool in $(REQUIRED_TOOLS); do \
		if ! command -v $$tool > /dev/null; then \
			echo "❌ Error: $$tool is not installed."; exit 1; \
		fi; \
	done
	@echo "✅ All tools installed."

install:
	@echo "🔧 Installing required tools with Homebrew..."
	@for tool in $(REQUIRED_TOOLS); do \
		if ! command -v $$tool > /dev/null; then \
			echo "📦 Installing $$tool..."; \
			brew install $$tool || { echo "❌ Failed to install $$tool"; exit 1; }; \
		else \
			echo "✅ $$tool already installed."; \
		fi; \
	done
	@echo "✅ All required tools are installed."

create-cluster:
	@echo "🔁 (Re)creating kind cluster: $(CLUSTER_NAME)"
	-kind delete cluster --name $(CLUSTER_NAME)
	kind create cluster --name $(CLUSTER_NAME)

create-namespace:
	@echo "📦 Creating namespace: $(CROSSPLANE_NAMESPACE)"
	kubectl create namespace $(CROSSPLANE_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

generate-cert:
	@echo "🔐 Generating TLS certificate"
	openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
		-keyout tls.key -out tls.crt \
		-config openssl-san.cnf -extensions req_ext
	@echo "📦 Creating Kubernetes secrets and configmaps"
	kubectl create secret tls $(CERT_NAME) --cert=tls.crt --key=tls.key -n $(REGISTRY_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap $(CONFIG_MAP_NAME) --from-file=tls.crt -n $(CROSSPLANE_NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	rm -f tls.key tls.crt

install-crossplane:
	@echo "📦 Installing Crossplane via Helm"
	helm repo add $(CHART_REPO_NAME) $(CHART_REPO_URL) || true
	helm repo update
	helm upgrade --install -f override.yaml $(CHART_NAME) \
		--namespace $(CROSSPLANE_NAMESPACE) $(CHART_REPO_NAME)/$(CHART_NAME)
	kubectl apply -f distribution.yaml
	kubectl rollout status deployment/oci-registry --timeout=60s -n $(REGISTRY_NAMESPACE)

build-image:
	@echo "🐳 Building Docker image: $(IMAGE_TAG)"
	docker build -t $(IMAGE_TAG) .

push-image:
	@echo "📦 Pushing image to kind and OCI registry"
	kind load docker-image $(IMAGE_TAG) --name $(CLUSTER_NAME)
	@echo "📡 Port-forwarding to OCI registry"
	@{ \
		kubectl port-forward svc/oci-registry 5000:443 -n $(REGISTRY_NAMESPACE) >/dev/null 2>&1 & \
		echo $$! > port_forward.pid; \
	}
	@echo "⏳ Waiting for registry to be reachable on port 5000..."
	@until nc -z localhost 5000; do sleep 1; done
	@echo "📤 Copying image with skopeo"
	skopeo copy --dest-tls-verify=false \
		docker-daemon:$(IMAGE_TAG) \
		docker://$(LOCAL_IMAGE)
	@$(MAKE) cleanup

deploy-function:
	@echo "🚀 Deploying Crossplane Function"
	@until kubectl get crd functions.pkg.crossplane.io >/dev/null 2>&1; do \
		echo "⏳ Waiting for Function CRD to be created..."; \
		sleep 1; \
	done
	kubectl wait --for=condition=Established crd/functions.pkg.crossplane.io --timeout=60s
	kubectl apply -f function.yaml

delete-function:
	@echo "🗑️ Deleting Crossplane Function"
	kubectl delete -f function.yaml

cleanup:
	@echo "🧹 Cleaning up port-forward"
	@if [ -f port_forward.pid ]; then \
		PID=$$(cat port_forward.pid); \
		if [ -n "$$PID" ] && kill -0 $$PID 2>/dev/null; then \
			echo "🔪 Killing port-forward process $$PID"; \
			kill $$PID; \
		else \
			echo "⚠️ PID $$PID is not running or invalid"; \
		fi; \
		rm -f port_forward.pid; \
	else \
		echo "ℹ️ No port_forward.pid file found"; \
	fi

redeploy-function:
	@echo "🔄 Redeploying Crossplane Function"
	@$(MAKE) build-image
	@$(MAKE) push-image
	@$(MAKE) delete-function
	@$(MAKE) deploy-function
	@echo "✅ Redeployment complete!"