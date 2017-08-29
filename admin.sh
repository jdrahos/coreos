#!/bin/bash
# script which genrates certificates needed to connect to the cluster, places them under local kubeclt config directory, 
# installs kubectl if not present in /usr/local/bin and sets it up to use the cluster

# ip of the master
export MASTER_HOST=10.201.12.37
# version of kubernetes/kubectl to install
export K8S_VER=v1.5.2
# version of helm to use
export HELM_VER=v2.1.3
# name of the cluster in kubectl configs
export CLUSTER_NAME=default
# certification authority certificate file
export CA_CERT=ca.pem
# certification authority key file
export CA_KEY=ca-key.pem
# administrator key file
export ADMIN_KEY=admin-key.pem
# administrator certificate
export ADMIN_CERT=admin.pem
# kubectl config dir to store the keys and certificates to
export KUBE_CONFIG_DIR=~/.kube/${CLUSTER_NAME}

function init_config {
    local REQUIRED=( 'MASTER_HOST' 'K8S_VER' 'HELM_VER' 'CLUSTER_NAME' 'CA_CERT' 'CA_KEY' 'ADMIN_KEY' 'ADMIN_CERT' 'KUBE_CONFIG_DIR' )

    for REQ in "${REQUIRED[@]}"; do
        if [ -z "$(eval echo \$$REQ)" ]; then
            echo "Missing required config value: ${REQ}"
            exit 1
        fi
    done
}

function generate_certificates {
    if [ ! -f "$CA_KEY" ]; then
        echo "Missing key file: $CA_KEY.pem"
        exit 1
    fi

    if [ ! -f "$CA_CERT" ]; then
        echo "Missing certificate file: $CA_CERT"
        exit 1
    fi

    if [ ! -f "$ADMIN_KEY" ]; then
        openssl genrsa -out "$ADMIN_KEY" 2048
    fi

    if [ ! -f admin.csr ]; then
        openssl req -new -key "$ADMIN_KEY" -out admin.csr -subj "/CN=kube-admin/O=system:masters"
    fi

    if [ ! -f "$ADMIN_CERT" ]; then
        openssl x509 -req -in admin.csr -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial -out "$ADMIN_CERT" -days 365
    fi

    #place the certificates and key to the cluster config directory
    mkdir -p "$KUBE_CONFIG_DIR"
    cp "$CA_CERT" "$KUBE_CONFIG_DIR"
    cp "$ADMIN_KEY" "$KUBE_CONFIG_DIR"
    cp "$ADMIN_CERT" "$KUBE_CONFIG_DIR"
}

function install_kubectl {
    if [ ! -f /usr/local/bin/kubectl ]; then
        curl -O https://storage.googleapis.com/kubernetes-release/release/$K8S_VER/bin/linux/amd64/kubectl
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/kubectl
    fi


    kubectl config set-cluster "$CLUSTER_NAME"-cluster --server=https://"$MASTER_HOST" --certificate-authority="$KUBE_CONFIG_DIR"/"$CA_CERT"
    kubectl config set-credentials "$CLUSTER_NAME"-admin --certificate-authority="$KUBE_CONFIG_DIR"/"$CA_CERT" --client-key="$KUBE_CONFIG_DIR"/"$ADMIN_KEY" --client-certificate="$KUBE_CONFIG_DIR"/"$ADMIN_CERT"
    kubectl config set-context "$CLUSTER_NAME"-system --cluster="$CLUSTER_NAME"-cluster --user="$CLUSTER_NAME"-admin
    kubectl config use-context "$CLUSTER_NAME"-system
}

function install_helm {
    if [ ! -f /usr/local/bin/helm ]; then
        wget https://kubernetes-helm.storage.googleapis.com/helm-"$HELM_VER"-linux-amd64.tar.gz
        tar -zxvf helm-"$HELM_VER"-linux-amd64.tar.gz
        chmod +x linux-amd64/helm
        sudo mv linux-amd64/helm /usr/local/bin/helm
        rm -rf linux-amd64
        rm helm-"$HELM_VER"-linux-amd64.tar.gz
    fi

    helm init
}

init_config
generate_certificates
#install_kubectl
#install_helm
