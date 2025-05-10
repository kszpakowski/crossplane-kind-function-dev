helm uninstall crossplane -n crossplane-system
kubectl delete function function-kcl
kubectl delete deployment oci-registry --force

openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout tls.key -out tls.crt -config openssl-san.cnf -extensions req_ext
kubectl create secret tls oci-registry-tls --cert=tls.crt --key=tls.key -o yaml --dry-run=client > manifests/distribution-tls.yaml
kubectl -n crossplane-system create configmap distribution-ca --from-file=tls.crt -o=yaml --dry-run=client > manifests/ca-cm.yaml
rm tls.key tls.crt

kubectl apply -f manifests/

helm install -f override.yaml crossplane --namespace crossplane-system --create-namespace crossplane-stable/crossplane