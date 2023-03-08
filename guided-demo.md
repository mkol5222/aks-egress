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

CPFRONTSUBNET_NAME="chkp_frontend-subnet"
CPFRONTSUBNET_IP="10.42.3.0/24"

CPBACKSUBNET_NAME="chkp_backend-subnet"
CPBACKSUBNET_IP="10.42.4.0/24"

LINUXSUBNET_NAME="linux-subnet"
LINUXSUBNET_IP="10.42.5.0/24"

PAASSUBNET_NAME="paas-subnet"
PAASSUBNET_IP="10.42.6.0/24"

AKSNAME=aks1
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
  --node-count 3 \
  --network-plugin azure \
  --outbound-type userDefinedRouting \
  --vnet-subnet-id $SUBNETID 
```

Run first Pod on AKS
```bash
az aks get-credentials -g $RG -n $AKSNAME

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
      - 10.42.1.0/24
      - 10.0.0.0/16
      - 10.42.0.0/16
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
kubectl get secret/cloudguard-controller -o json | jq -r .data.token

# note API server URL:
kubectl cluster-info

```


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