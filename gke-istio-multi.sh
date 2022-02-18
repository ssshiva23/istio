#!/bin/bash

set -x

#create control and remote cluster
gcloud services enable container.googleapis.com
gcloud container clusters create control --zone us-west2-a \
    --machine-type "e2-standard-4" --disk-size "100" \
    --num-nodes "1" --network "default" --enable-ip-alias --async

gcloud container clusters create remote --zone us-central1-f \
    --machine-type "e2-standard-4" --disk-size "100" \
    --num-nodes "1" --network "default" --enable-ip-alias
 

export MAIN_CLUSTER_CTX=control
export MAIN_CLUSTER_NAME=control
export REMOTE_CLUSTER_CTX=remote
export REMOTE_CLUSTER_NAME=remote

export MAIN_CLUSTER_NETWORK=network1
export REMOTE_CLUSTER_NETWORK=network1

for CTX in $MAIN_CLUSTER_CTX $REMOTE_CLUSTER_CTX
do
kubectl create namespace istio-system --context $CTX
kubectl --context=$CTX create secret generic cacerts -n istio-system \
    --from-file=samples/certs/ca-cert.pem \
    --from-file=samples/certs/ca-key.pem \
    --from-file=samples/certs/root-cert.pem \
    --from-file=samples/certs/cert-chain.pem
done

cat <<EOF> istio-main-cluster.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      multiCluster:
        clusterName: ${MAIN_CLUSTER_NAME}
      network: ${MAIN_CLUSTER_NETWORK}
  # Change the Istio service `type=LoadBalancer` and add the cloud provider specific annotations. See
  # https://kubernetes.io/docs/concepts/services-networking/service/#internal-load-balancer for more
  # information. The example below shows the configuration for GCP/GKE.
  components:
    pilot:
      k8s:
        service:
          type: LoadBalancer
        service_annotations:
          cloud.google.com/load-balancer-type: Internal
          networking.gke.io/internal-load-balancer-allow-global-access: "true"
EOF
istioctl install -f istio-main-cluster.yaml --context=${MAIN_CLUSTER_CTX}
kubectl get pod -n istio-system --context=${MAIN_CLUSTER_CTX}
echo "Sleeping for 10 seconds to wait for Internal Load Balancer to come up"
sleep 10s
export ISTIOD_REMOTE_EP=$(kubectl get svc -n istio-system --context=${MAIN_CLUSTER_CTX} istiod -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "ISTIOD_REMOTE_EP is ${ISTIOD_REMOTE_EP}"
read -n 1 -s -r -p "Press any key to continue"
cat <<EOF> istio-remote0-cluster.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      # The remote cluster's name and network name must match the values specified in the
      # mesh network configuration of the main cluster.
      multiCluster:
        clusterName: ${REMOTE_CLUSTER_NAME}
      network: ${REMOTE_CLUSTER_NETWORK}
      # Replace ISTIOD_REMOTE_EP with the the value of ISTIOD_REMOTE_EP set earlier.
      remotePilotAddress: ${ISTIOD_REMOTE_EP}
EOF
istioctl install -f istio-remote0-cluster.yaml --context ${REMOTE_CLUSTER_CTX}
kubectl get pod -n istio-system --context=${REMOTE_CLUSTER_CTX}
istioctl x create-remote-secret --name ${REMOTE_CLUSTER_NAME} --context=${REMOTE_CLUSTER_CTX} | \
        kubectl apply -f - --context=${MAIN_CLUSTER_CTX}
read -n 1 -s -r -p "Press any key to continue"
## Deploy a sample app
kubectl create namespace sample --context=${REMOTE_CLUSTER_CTX}
kubectl label namespace sample istio-injection=enabled --context=${REMOTE_CLUSTER_CTX}
kubectl create -f samples/helloworld/helloworld.yaml -l app=helloworld -n sample --context=${REMOTE_CLUSTER_CTX}
kubectl create -f samples/helloworld/helloworld.yaml -l version=v2 -n sample --context=${REMOTE_CLUSTER_CTX}
kubectl get pod -n sample --context=${REMOTE_CLUSTER_CTX}
kubectl create namespace sample --context=${MAIN_CLUSTER_CTX}
kubectl label namespace sample istio-injection=enabled --context=${MAIN_CLUSTER_CTX}
kubectl create -f samples/helloworld/helloworld.yaml -l app=helloworld -n sample --context=${MAIN_CLUSTER_CTX}
kubectl create -f samples/helloworld/helloworld.yaml -l version=v1 -n sample --context=${MAIN_CLUSTER_CTX}
kubectl get pod -n sample --context=${MAIN_CLUSTER_CTX}
echo "Testing cross cluster routing"
kubectl apply -f samples/sleep/sleep.yaml -n sample --context=${MAIN_CLUSTER_CTX}
kubectl apply -f samples/sleep/sleep.yaml -n sample --context=${REMOTE_CLUSTER_CTX}
echo "Waiting for pods to start. Going to sleep for 20 seconds"
sleep 20s
kubectl get pod -n sample -l app=sleep --context=${MAIN_CLUSTER_CTX}
kubectl get pod -n sample -l app=sleep --context=${REMOTE_CLUSTER_CTX}
echo "Calling the service 10 times from the main cluster"
for i in {1..10}
do
kubectl exec -it -n sample -c sleep --context=${MAIN_CLUSTER_CTX} $(kubectl get pod -n sample -l app=sleep --context=${MAIN_CLUSTER_CTX} -o jsonpath='{.items[0].metadata.name}') -- curl helloworld.sample:5000/hello
done
echo "Calling the service 10 times from the remote cluster"
for i in {1..10}
do
kubectl exec -it -n sample -c sleep --context=${REMOTE_CLUSTER_CTX} $(kubectl get pod -n sample -l app=sleep --context=${REMOTE_CLUSTER_CTX} -o jsonpath='{.items[0].metadata.name}') -- curl helloworld.sample:5000/hello
done