#!/bin/bash

IMAGE_TAG="oci-registry.default.svc.cluster.local/crossplane-contrib/function-kcl:v0.11.4"

set -e
cleanup() {
    echo "Stopping port-forward (PID $PORT_FORWARD_PID)"
    kill $PORT_FORWARD_PID
}
trap cleanup EXIT

echo "Building and pushing image to OCI registry"

echo "Creating port-forward to OCI registry"
kubectl port-forward svc/oci-registry 5000:443 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!

echo "building image"
docker build -t $IMAGE_TAG .

echo "Copying node to kind"
kind load docker-image $IMAGE_TAG --name oci-mock

echo "Pushing image to OCI registry"
skopeo copy --dest-tls-verify=false \
  docker-daemon:$IMAGE_TAG \
  docker://localhost:5000/crossplane-contrib/function-kcl:v0.11.4