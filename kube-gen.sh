#/bin/bash

function check_parm()
{
  if [ "${2}" == "" ]; then
    echo -n "${1}"
    return 1
  else
    return 0
  fi
}

if [ -f ./cluster-info ]; then
	source ./cluster-info 
fi

check_parm "Enter the IP address of master-01: " ${CP0_IP} 
if [ $? -eq 1 ]; then
	read CP0_IP
fi
check_parm "Enter the IP address of master-02: " ${CP1_IP}
if [ $? -eq 1 ]; then
	read CP1_IP
fi
check_parm "Enter the IP address of master-03: " ${CP2_IP}
if [ $? -eq 1 ]; then
	read CP2_IP
fi
check_parm "Enter the VIP: " ${VIP}
if [ $? -eq 1 ]; then
	read VIP
fi
check_parm "Enter the Net Interface: " ${NET_IF}
if [ $? -eq 1 ]; then
	read NET_IF
fi
check_parm "Enter the cluster CIDR: " ${CIDR}
if [ $? -eq 1 ]; then
	read CIDR
fi

echo """
cluster-info:
  master-01:        ${CP0_IP}
  master-02:        ${CP1_IP}
  master-02:        ${CP2_IP}
  VIP:              ${VIP}
  Net Interface:    ${NET_IF}
  CIDR:             ${CIDR}
"""
echo -n 'Please print "yes" to continue or "no" to cancel: '
read AGREE
while [ "${AGREE}" != "yes" ]; do
	if [ "${AGREE}" == "no" ]; then
		exit 0;
	else
		echo -n 'Please print "yes" to continue or "no" to cancel: '
		read AGREE
	fi
done

mkdir -p ~/ikube/tls

IPS=(${CP0_IP} ${CP1_IP} ${CP2_IP})

PRIORITY=(100 50 30)
STATE=("MASTER" "BACKUP" "BACKUP")
HEALTH_CHECK=""
for index in 0 1 2; do
  HEALTH_CHECK=${HEALTH_CHECK}"""
    real_server ${IPS[$index]} 6443 {
        weight 1
        SSL_GET {
            url {
              path /healthz
              status_code 200
            }
            connect_timeout 3
            nb_get_retry 3
            delay_before_retry 3
        }
    }
"""
done

  echo """
global
    log         127.0.0.1 local2
    chroot      /var/lib/haproxy
    pidfile     /var/run/haproxy.pid
    maxconn     4000
    user        haproxy
    group       haproxy
    daemon
    stats socket /var/lib/haproxy/stats

defaults
    mode                    tcp
    log                     global
    option                  tcplog
    option                  dontlognull
    option                  redispatch
    retries                 3
    timeout queue           1m
    timeout connect         10s
    timeout client          1m
    timeout server          1m
    timeout check           10s
    maxconn                 3000

listen stats
    mode   http
    bind :10086
    stats   enable
    stats   uri     /admin?stats
    stats   auth    admin:admin
    stats   admin   if TRUE
    
frontend  k8s_https *:8443
    mode      tcp
    maxconn      2000
    default_backend     https_sri
    
backend https_sri
    balance      roundrobin
    server master1-api ${CP0_IP}:6443  check inter 10000 fall 2 rise 2 weight 1
    server master2-api ${CP1_IP}:6443  check inter 10000 fall 2 rise 2 weight 1
    server master3-api ${CP2_IP}:6443  check inter 10000 fall 2 rise 2 weight 1
""" > ~/ikube/haproxy.cfg

for index in 0 1 2; do
  ip=${IPS[${index}]}
  echo """
global_defs {
   router_id LVS_DEVEL
}

vrrp_script check_haproxy {
    script "/etc/keepalived/check_haproxy.sh"
    interval 3
}

vrrp_instance VI_1 {
    state ${STATE[${index}]}
    interface ${NET_IF}
    virtual_router_id 80
    priority ${PRIORITY[${index}]}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass just0kk
    }
    virtual_ipaddress {
        ${VIP}/24
    }
    track_script {   
        check_haproxy
    }
}

}
""" > ~/ikube/keepalived-${index}.conf
  scp ~/ikube/keepalived-${index}.conf ${ip}:/etc/keepalived/keepalived.conf
  scp ~/ikube/haproxy.cfg ${ip}:/etc/haproxy/haproxy.cfg

  ssh ${ip} "
    systemctl stop keepalived
    systemctl enable keepalived
    systemctl start keepalived
    systemctl stop haproxy
    systemctl enable haproxy
    systemctl start haproxy
    kubeadm reset -f
    rm -rf /etc/kubernetes/pki/"
done

echo """
apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
kubernetesVersion: v1.13.0
controlPlaneEndpoint: "${VIP}:8443"
apiServer:
  certSANs:
  - ${CP0_IP}
  - ${CP1_IP}
  - ${CP2_IP}
  - ${VIP}
  extraArgs: 
    service-node-port-range: "1-65535"
networking:
  # This CIDR is a Calico default. Substitute or remove for your CNI provider.
  podSubnet: ${CIDR}
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
""" > /etc/kubernetes/kubeadm-config.yaml

kubeadm init --config /etc/kubernetes/kubeadm-config.yaml
mkdir -p $HOME/.kube
cp -f /etc/kubernetes/admin.conf ${HOME}/.kube/config

kubectl apply -f https://raw.githubusercontent.com/hnbcao/kubeadm-ha-master/v1.3.0/calico/rbac.yaml
curl -fsSL https://raw.githubusercontent.com/hnbcao/kubeadm-ha-master/v1.3.0/calico/calico.yaml | sed "s!8.8.8.8!${CP0_IP}!g" | sed "s!10.244.0.0/16!${CIDR}!g" | kubectl apply -f -

JOIN_CMD=`kubeadm token create --print-join-command`

for index in 1 2; do
  ip=${IPS[${index}]}
  ssh $ip "mkdir -p /etc/kubernetes/pki/etcd; mkdir -p ~/.kube/"
  scp /etc/kubernetes/pki/ca.crt $ip:/etc/kubernetes/pki/ca.crt
  scp /etc/kubernetes/pki/ca.key $ip:/etc/kubernetes/pki/ca.key
  scp /etc/kubernetes/pki/sa.key $ip:/etc/kubernetes/pki/sa.key
  scp /etc/kubernetes/pki/sa.pub $ip:/etc/kubernetes/pki/sa.pub
  scp /etc/kubernetes/pki/front-proxy-ca.crt $ip:/etc/kubernetes/pki/front-proxy-ca.crt
  scp /etc/kubernetes/pki/front-proxy-ca.key $ip:/etc/kubernetes/pki/front-proxy-ca.key
  scp /etc/kubernetes/pki/etcd/ca.crt $ip:/etc/kubernetes/pki/etcd/ca.crt
  scp /etc/kubernetes/pki/etcd/ca.key $ip:/etc/kubernetes/pki/etcd/ca.key
  scp /etc/kubernetes/admin.conf $ip:/etc/kubernetes/admin.conf
  scp /etc/kubernetes/admin.conf $ip:~/.kube/config

  ssh ${ip} "${JOIN_CMD} --experimental-control-plane"
done

echo "Cluster create finished."

echo """
[req] 
distinguished_name = req_distinguished_name
prompt = yes

[ req_distinguished_name ]
countryName                     = Country Name (2 letter code)
countryName_value               = CN

stateOrProvinceName             = State or Province Name (full name)
stateOrProvinceName_value       = ChongQing

localityName                    = Locality Name (eg, city)
localityName_value              = Yubei

organizationName                = Organization Name (eg, company)
organizationName_value          = CISDI

organizationalUnitName          = Organizational Unit Name (eg, section)
organizationalUnitName_value    = R & D Department

commonName                      = Common Name (eg, your name or your server\'s hostname)
commonName_value                = *.cisdi.com.cn


emailAddress                    = Email Address
emailAddress_value              = hnbcao@gmail.com
""" > ~/ikube/tls/openssl.cnf
openssl req -newkey rsa:4096 -nodes -config ~/ikube/tls/openssl.cnf -days 3650 -x509 -out ~/ikube/tls/tls.crt -keyout ~/ikube/tls/tls.key
kubectl create -n kube-system secret tls ssl --cert ~/ikube/tls/tls.crt --key ~/ikube/tls/tls.key
#kubectl apply -f /root/ingress.yaml
kubectl apply -f https://raw.githubusercontent.com/hnbcao/kubeadm-ha-master/v1.3.0/plugin/metrics.yaml
#kubectl apply -f https://raw.githubusercontent.com/Lentil1016/kubeadm-ha/1.13.0/plugin/kubernetes-dashboard.yaml

echo "Plugin install finished."
echo "Waiting for all pods into 'Running' status. You can press 'Ctrl + c' to terminate this waiting any time you like."
POD_UNREADY=`kubectl get pods -n kube-system 2>&1|awk '{print $3}'|grep -vE 'Running|STATUS'`
NODE_UNREADY=`kubectl get nodes 2>&1|awk '{print $2}'|grep 'NotReady'`
while [ "${POD_UNREADY}" != "" -o "${NODE_UNREADY}" != "" ]; do
  sleep 1
  POD_UNREADY=`kubectl get pods -n kube-system 2>&1|awk '{print $3}'|grep -vE 'Running|STATUS'`
  NODE_UNREADY=`kubectl get nodes 2>&1|awk '{print $2}'|grep 'NotReady'`
done

echo

kubectl get cs
kubectl get nodes
kubectl get pods -n kube-system

echo """
join command:
  `kubeadm token create --print-join-command`"""