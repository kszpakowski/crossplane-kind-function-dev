#!/bin/bash
set -euo pipefail

CLUSTER_NAME="crossplane-local"
NAMESPACE="crossplane-system"
MANIFEST_DIR="manifests"
CERT_NAME="oci-registry-tls"
CONFIG_MAP_NAME="distribution-ca"
CHART_NAME="crossplane"
CHART_REPO_NAME="crossplane-stable"
CHART_REPO_URL="https://charts.crossplane.io/stable"
IMAGE_TAG="oci-registry.default.svc.cluster.local/crossplane-contrib/function-kcl:v0.11.4"


kind delete cluster --name crossplane-local

echo "Creating kind cluster: $CLUSTER_NAME"
kind create cluster --name "$CLUSTER_NAME" || {
  echo "Cluster $CLUSTER_NAME already exists or failed to create"; exit 1;
}

echo "Creating namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" || {
  echo "Namespace $NAMESPACE already exists or failed to create"; exit 1;
}

echo "Creating TLS certificate"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -config openssl-san.cnf -extensions req_ext

echo "Generating Kubernetes TLS secret manifest"
kubectl create secret tls "$CERT_NAME" \
  --cert=tls.crt --key=tls.key

echo "Generating CA ConfigMap manifest"
kubectl create configmap "$CONFIG_MAP_NAME" \
  --from-file=tls.crt -n "$NAMESPACE"

echo "Cleaning up local cert files"
rm -f tls.key tls.crt


echo "Adding and updating Helm repo"
helm repo add "$CHART_REPO_NAME" "$CHART_REPO_URL"
helm repo update

echo "Installing Crossplane via Helm"
helm install -f override.yaml "$CHART_NAME" \
  --namespace "$NAMESPACE" "$CHART_REPO_NAME/$CHART_NAME"

echo "Applying oci-registry manifest"
kubectl apply -f "distribution.yaml"

echo "Waiting for oci-registry deployment rollout"
kubectl rollout status deployment/oci-registry --timeout=60s




# ---- build and deploy docker image ----

echo "Building and pushing image to OCI registry"

cleanup() {
    echo "Stopping port-forward (PID $PORT_FORWARD_PID)"
    kill $PORT_FORWARD_PID
}
trap cleanup EXIT

echo "Creating port-forward to OCI registry"
kubectl port-forward svc/oci-registry 5000:443 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!

echo "building image"
docker build -t $IMAGE_TAG .

echo "Copying node to kind"
kind load docker-image $IMAGE_TAG --name $CLUSTER_NAME

echo "Pushing image to OCI registry"
skopeo copy --dest-tls-verify=false \
  docker-daemon:$IMAGE_TAG \
  docker://localhost:5000/crossplane-contrib/function-kcl:v0.11.4


# ---- deploying function ----

until kubectl get crd functions.pkg.crossplane.io >/dev/null 2>&1; do
  echo "Waiting for Function CRD to be created..."
  sleep 1
done

kubectl wait --for=condition=Established crd/functions.pkg.crossplane.io --timeout=60s

kubectl apply -f function.yaml

echo "Setup complete!"