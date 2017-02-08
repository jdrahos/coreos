#Kubernetes on CoreOS
This repository holds scripts which can be used to set up kubernetes on coreos host.
Before you run the scripts check and modify values on top of the scripts as desired. Scripts won't modify files which exist already so it is safe to run them several times.

These scripts are based on the information found in:
https://coreos.com/kubernetes/docs/latest/getting-started.html
https://coreos.com/kubernetes/docs/latest/kubernetes-on-generic-platforms.html
https://coreos.com/kubernetes/docs/latest/openssl.html

- **master.sh** You will need to run the script with sudo. Script generates certification authority key and certificate which need to be used in the other scripts. On top of that it will generate key and certificate for the api server and place everything needed in /etc/kubernetes/ssl directory. if LOCAL_ETCD_ENDPOINT is set it will install etcd2 node and run it as container. The adverised IP in config will be setup as a static IP by the script using systemd unit. The script sets up and enables systemd units related to kubernetesunits but will start only those needed to populate etcd2 with network configuration for flannel. Script will reboot the server at the end (you get 10s to interrupt it).
- **worker.sh** You will need to run the script with sudo. Script needs the certification authority key and certificate present in current work directory. It will use them to generate worker certificate and key and place everything into /etc/kubernetes/ssl directory. The adverised IP in config will be setup as a static IP by the script using systemd unit. The script only creates/modifies and enables systemd units related to kubernetesunits but won't start them. Script will reboot the server at the end (you get 10s to interrupt it).
- **admin.sh** Script needs the certification authority key and certificate present in current work directory. It generates admin key and certificate and places them inside a folder in ~/.kube directory so it can be referenced by kubectl configuration. It will install kubectl if it is missing in /usr/local/bin directory and set it up to use the kubernetes cluster from configuration.

