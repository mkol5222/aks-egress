
kubectl create serviceaccount cloudguard-controller

kubectl create clusterrole endpoint-reader --verb=get,list --resource=endpoints

kubectl create clusterrolebinding allow-cloudguard-access-endpoints --clusterrole=endpoint-reader --serviceaccount=default:cloudguard-controller

kubectl create clusterrole pod-reader --verb=get,list --resource=pods

kubectl create clusterrolebinding allow-cloudguard-access-pods --clusterrole=pod-reader --serviceaccount=default:cloudguard-controller

kubectl create clusterrole service-reader --verb=get,list --resource=services

kubectl create clusterrolebinding allow-cloudguard-access-services --clusterrole=service-reader --serviceaccount=default:cloudguard-controller

kubectl create clusterrole node-reader --verb=get,list --resource=nodes

kubectl create clusterrolebinding allow-cloudguard-access-nodes --clusterrole=node-reader --serviceaccount=default:cloudguard-controller


kubectl cluster-info

# cat <<EOF | kubectl apply -f -
# apiVersion: v1
# kind: Secret
# type: kubernetes.io/service-account-token
# metadata:
#   name: cloudguard-controller
#   annotations:
#     kubernetes.io/service-account.name: "cloudguard-controller"
# EOF

kubectl apply -f ./cg-sa-secret.yml
kubectl get secret cloudguard-controller -o yaml
kubectl get sa cloudguard-controller -o yaml 
#kubectl get secret $(kubectl get serviceaccount cloudguard-controller -o jsonpath="{.secrets[0].name}") -o jsonpath="{.data.token}" | base64 --decode -w 0 > token_file
