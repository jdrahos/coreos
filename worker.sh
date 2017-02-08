#!/bin/bash
#script based on https://github.com/coreos/coreos-kubernetes/blob/master/multi-node/generic/worker-install.sh
set -e

#set to name of the network interface to use
export NIC=enp0s8

# set to routable host ip. By default use current IP
export ADVERTISE_IP=$(ifconfig $NIC | grep 'inet ' | awk '{print $2}')

# set to fully qualified hostname. Uses current hostname by default
export FQDN=$(hostname)

# List of etcd servers (http://ip:port), comma separated
export ETCD_ENDPOINTS=

# The endpoint the worker node should use to contact controller nodes (https://ip:port)
# In HA configurations this should be an external DNS record or loadbalancer in front of the control nodes.
# However, it is also possible to point directly to a single control node.
export CONTROLLER_ENDPOINT=

# Specify the version (vX.Y.Z) of Kubernetes assets to deploy
export K8S_VER=v1.5.2_coreos.0

# Hyperkube image repository to use.
export HYPERKUBE_IMAGE_REPO=quay.io/coreos/hyperkube

# The CIDR network to use for pod IPs.
# Each pod launched in the cluster will be assigned an IP out of this range.
# Each node will be configured such that these IPs will be routable using the flannel overlay network.
export POD_NETWORK=10.2.0.0/16

# The IP address of the cluster DNS service.
# This must be the same DNS_SERVICE_IP used when configuring the controller nodes.
export DNS_SERVICE_IP=10.3.0.10

# Determines the container runtime for kubernetes to use. Accepts 'docker' or 'rkt'.
export CONTAINER_RUNTIME=docker

# The above settings can optionally be overridden using an environment file:
ENV_FILE=/run/coreos-kubernetes/options.env

# -------------

function init_config {
    local REQUIRED=( 'ADVERTISE_IP' 'ETCD_ENDPOINTS' 'CONTROLLER_ENDPOINT' 'DNS_SERVICE_IP' 'K8S_VER' 'HYPERKUBE_IMAGE_REPO' 'NIC' )

    if [ -f $ENV_FILE ]; then
        export $(cat $ENV_FILE | xargs)
    fi

    if [ -z $ADVERTISE_IP ]; then
        export ADVERTISE_IP=$(awk -F= '/COREOS_PUBLIC_IPV4/ {print $2}' /etc/environment)
    fi

    for REQ in "${REQUIRED[@]}"; do
        if [ -z "$(eval echo \$$REQ)" ]; then
            echo "Missing required config value: ${REQ}"
            exit 1
        fi
    done
}

function generate_certificates {
    if [ ! -f ca-key.pem ]; then
        echo "Missing key file: ca-key.pem"
        exit 1
    fi

    if [ ! -f ca.pem ]; then
        echo "Missing certificate file: ca.pem"
        exit 1
    fi

    if [ ! -f ${FQDN}-worker-key.pem ]; then
        openssl genrsa -out ${FQDN}-worker-key.pem 2048
    fi

        local TEMPLATE=worker-openssl.cnf
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
IP.1 = ${ADVERTISE_IP}
EOF
    fi

    if [ ! -f ${FQDN}-worker.csr ]; then
        ADVERTISE_IP=${ADVERTISE_IP} openssl req -new -key ${FQDN}-worker-key.pem -out ${FQDN}-worker.csr -subj "/CN=${FQDN}" -config worker-openssl.cnf
    fi

    if [ ! -f apiserver-key.pem ]; then
        ADVERTISE_IP=${ADVERTISE_IP} openssl x509 -req -in ${FQDN}-worker.csr -CA ca.pem -CAkey ca-key.pem -CAcreateserial -out ${FQDN}-worker.pem -days 365 -extensions v3_req -extfile worker-openssl.cnf
    fi

    mkdir -p /etc/kubernetes/ssl/
    cp ${FQDN}-worker.pem /etc/kubernetes/ssl/worker.pem
    cp ${FQDN}-worker-key.pem /etc/kubernetes/ssl/worker-key.pem
    cp ca.pem /etc/kubernetes/ssl/

    chmod 600 /etc/kubernetes/ssl/*-key.pem
    chown root:root /etc/kubernetes/ssl/*.pem
}

function init_templates {
    local gatewayIp=$(route -n | grep $NIC | grep G | awk '{print $2}')
    local dnsConfig=$(for dns in `grep nameserver /etc/resolv.conf | awk '{print $2}'`; do echo "DNS=$dns"; done)
    local TEMPLATE=/etc/systemd/network/static.network
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Match]
Name=$NIC

[Network]
Address= $ADVERTISE_IP/24
Gateway=${gatewayIp}
${dnsConfig}

EOF
    fi
    
    local TEMPLATE=/etc/systemd/system/kubelet.service
    local uuid_file="/var/run/kubelet-pod.uuid"
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Description=Kubernetes node agent
After=docker.service flanneld.service
Before=flannel-docker-opts.service
Wants=flannel-docker-opts.service
[Service]
Environment=KUBELET_VERSION=${K8S_VER}
Environment=KUBELET_ACI=${HYPERKUBE_IMAGE_REPO}
Environment="RKT_OPTS=--uuid-file-save=${uuid_file} \
  --volume dns,kind=host,source=/etc/resolv.conf \
  --mount volume=dns,target=/etc/resolv.conf \
  --volume rkt,kind=host,source=/opt/bin/host-rkt \
  --mount volume=rkt,target=/usr/bin/rkt \
  --volume var-lib-rkt,kind=host,source=/var/lib/rkt \
  --mount volume=var-lib-rkt,target=/var/lib/rkt \
  --volume stage,kind=host,source=/tmp \
  --mount volume=stage,target=/tmp \
  --volume var-log,kind=host,source=/var/log \
  --mount volume=var-log,target=/var/log"
ExecStartPre=/usr/bin/mkdir -p /etc/kubernetes/manifests
ExecStartPre=/usr/bin/mkdir -p /var/log/containers
ExecStartPre=-/usr/bin/rkt rm --uuid-file=${uuid_file}
ExecStartPre=/usr/bin/mkdir -p /opt/cni/bin
ExecStart=/usr/lib/coreos/kubelet-wrapper \
  --api-servers=${CONTROLLER_ENDPOINT} \
  --cni-conf-dir=/etc/kubernetes/cni/net.d \
  --network-plugin=cni \
  --container-runtime=${CONTAINER_RUNTIME} \
  --rkt-path=/usr/bin/rkt \
  --rkt-stage1-image=coreos.com/rkt/stage1-coreos \
  --register-node=true \
  --allow-privileged=true \
  --pod-manifest-path=/etc/kubernetes/manifests \
  --hostname-override=${ADVERTISE_IP} \
  --cluster_dns=${DNS_SERVICE_IP} \
  --cluster_domain=cluster.local \
  --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml \
  --tls-cert-file=/etc/kubernetes/ssl/worker.pem \
  --tls-private-key-file=/etc/kubernetes/ssl/worker-key.pem
ExecStop=-/usr/bin/rkt stop --uuid-file=${uuid_file}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    fi

    local TEMPLATE=/opt/bin/host-rkt
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
#!/bin/sh
# This is bind mounted into the kubelet rootfs and all rkt shell-outs go
# through this rkt wrapper. It essentially enters the host mount namespace
# (which it is already in) only for the purpose of breaking out of the chroot
# before calling rkt. It makes things like rkt gc work and avoids bind mounting
# in certain rkt filesystem dependancies into the kubelet rootfs. This can
# eventually be obviated when the write-api stuff gets upstream and rkt gc is
# through the api-server. Related issue:
# https://github.com/coreos/rkt/issues/2878
exec nsenter -m -u -i -n -p -t 1 -- /usr/bin/rkt "\$@"
EOF
    fi

    local TEMPLATE=/etc/systemd/system/load-rkt-stage1.service
    if [ ${CONTAINER_RUNTIME} = "rkt" ] && [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Description=Load rkt stage1 images
Documentation=http://github.com/coreos/rkt
Requires=network-online.target
After=network-online.target
Before=rkt-api.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/rkt fetch /usr/lib/rkt/stage1-images/stage1-coreos.aci /usr/lib/rkt/stage1-images/stage1-fly.aci  --insecure-options=image

[Install]
RequiredBy=rkt-api.service
EOF
    fi

    local TEMPLATE=/etc/systemd/system/rkt-api.service
    if [ ${CONTAINER_RUNTIME} = "rkt" ] && [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Before=kubelet.service

[Service]
ExecStart=/usr/bin/rkt api-service
Restart=always
RestartSec=10

[Install]
RequiredBy=kubelet.service
EOF
    fi

    local TEMPLATE=/etc/kubernetes/worker-kubeconfig.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    certificate-authority: /etc/kubernetes/ssl/ca.pem
users:
- name: kubelet
  user:
    client-certificate: /etc/kubernetes/ssl/worker.pem
    client-key: /etc/kubernetes/ssl/worker-key.pem
contexts:
- context:
    cluster: local
    user: kubelet
  name: kubelet-context
current-context: kubelet-context
EOF
    fi

    local TEMPLATE=/etc/kubernetes/manifests/kube-proxy.yaml
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-proxy
  namespace: kube-system
  annotations:
    rkt.alpha.kubernetes.io/stage1-name-override: coreos.com/rkt/stage1-fly
spec:
  hostNetwork: true
  containers:
  - name: kube-proxy
    image: ${HYPERKUBE_IMAGE_REPO}:$K8S_VER
    command:
    - /hyperkube
    - proxy
    - --master=${CONTROLLER_ENDPOINT}
    - --cluster-cidr=${POD_NETWORK}
    - --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml
    securityContext:
      privileged: true
    volumeMounts:
    - mountPath: /etc/ssl/certs
      name: "ssl-certs"
    - mountPath: /etc/kubernetes/worker-kubeconfig.yaml
      name: "kubeconfig"
      readOnly: true
    - mountPath: /etc/kubernetes/ssl
      name: "etc-kube-ssl"
      readOnly: true
    - mountPath: /var/run/dbus
      name: dbus
      readOnly: false
  volumes:
  - name: "ssl-certs"
    hostPath:
      path: "/usr/share/ca-certificates"
  - name: "kubeconfig"
    hostPath:
      path: "/etc/kubernetes/worker-kubeconfig.yaml"
  - name: "etc-kube-ssl"
    hostPath:
      path: "/etc/kubernetes/ssl"
  - hostPath:
      path: /var/run/dbus
    name: dbus
EOF
    fi

    local TEMPLATE=/etc/flannel/options.env
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
FLANNELD_IFACE=$ADVERTISE_IP
FLANNELD_ETCD_ENDPOINTS=$ETCD_ENDPOINTS
EOF
    fi

    local TEMPLATE=/etc/systemd/system/flanneld.service.d/40-ExecStartPre-symlink.conf
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Service]
ExecStartPre=/usr/bin/ln -sf /etc/flannel/options.env /run/flannel/options.env
EOF
    fi

    local TEMPLATE=/etc/systemd/system/docker.service.d/40-flannel.conf
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Requires=flanneld.service
After=flanneld.service
[Service]
EnvironmentFile=/etc/kubernetes/cni/docker_opts_cni.env
EOF
    fi

    local TEMPLATE=/etc/kubernetes/cni/docker_opts_cni.env
    if [ ! -f $TEMPLATE ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
DOCKER_OPT_BIP=""
DOCKER_OPT_IPMASQ=""
EOF

    fi

    local TEMPLATE=/etc/kubernetes/cni/net.d/10-flannel.conf
    if [ ! -f "${TEMPLATE}" ]; then
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
{
    "name": "podnet",
    "type": "flannel",
    "delegate": {
        "isDefaultGateway": true
    }
}
EOF
    fi

}

init_config
generate_certificates
init_templates

chmod +x /opt/bin/host-rkt
systemctl stop update-engine; systemctl mask update-engine
systemctl daemon-reload
systemctl enable docker;
systemctl enable flanneld;
systemctl enable kubelet;

if [ $CONTAINER_RUNTIME = "rkt" ]; then
        systemctl enable load-rkt-stage1
        systemctl enable rkt-api
fi


echo "DONE"
echo "Going to reboot in 10 seconds"

sleep 10
reboot