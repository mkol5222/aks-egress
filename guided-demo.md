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
AKSSUBNET_NAME="aks-subnet"

LINUXSUBNET_NAME="linux-subnet"
PAASSUBNET_NAME="paas-subnet"

AKSNAME=aks1
```

## Create VNET and subnets

```bash
az group create --name $RG --location $LOC

az network vnet create \
    --resource-group $RG \
    --name $VNET_NAME \
    --location $LOC \
    --address-prefixes 10.42.0.0/16 \
    --subnet-name $AKSSUBNET_NAME \
    --subnet-prefix 10.42.1.0/24

az network vnet subnet create \
    --resource-group $RG \
    --vnet-name $VNET_NAME \
    --name "chkp_frontend-subnet" \
    --address-prefix 10.42.3.0/24
    
az network vnet subnet create \
    --resource-group $RG \
    --vnet-name $VNET_NAME \
    --name "chkp_backend-subnet" \
    --address-prefix 10.42.4.0/24

az network vnet subnet create \
    --resource-group $RG \
    --vnet-name $VNET_NAME \
    --name $LINUXSUBNET_NAME \
    --address-prefix 10.42.5.0/24

az network vnet subnet create \
    --resource-group $RG \
    --vnet-name $VNET_NAME \
    --name $PAASSUBNET_NAME \
    --address-prefix 10.42.6.0/24
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
for P in $(kubectl get pod -l 'app=web2' -o name); do kubectl exec -it $P -- curl ifconfig.me ; echo ; done
```
