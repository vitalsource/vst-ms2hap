#!/bin/bash
set -ex

apt-get update -qq
apt-get install haproxy -yqq

my_ipcalc=$(which ipcalc 2> /dev/null)

if [ "${my_ipcalc}" != "" ]; then

    while [ "${cloud_memory_store_ip}" = "" ]; do
        read -p "Enter the IP address of your Google Cloud Memory Store Instance: " user_input
        let is_ip=$(${my_ipcalc} ${user_input} 2>&1 | egrep -ic "^invalid")
    
        if [ ${is_ip} -eq 0 ]; then
            cloud_memory_store_ip="${user_input}"
        fi
    
    done
    
    if [ -d ./etc -a "${cloud_memory_store_ip}" != "" ]; then
        sysctl_conf="/etc/sysctl.conf"
        security_limits_conf="/etc/security/limits.conf"
        haproxy_conf="/etc/haproxy/haproxy.conf"
    
        if [ -f .${sysctl_conf} ]; then
            awk '{print $0}' .${sysctl_conf} >> ${sysctl_conf}
            sysctl -p
        fi
    
        if [ -e .${security_limits_conf} ]; then
            awk '{print $0}' .${security_limits_conf} >> ${security_limits_conf}
        fi
    
        if [ -e .${haproxy_conf} ]; then
            awk '{print $0}' .${haproxy_conf} > ${haproxy_conf}
            sed -i -e "s/::CLOUD_MEMORY_STORE_IP::/${cloud_memory_store_ip}/g" ${haproxy_conf}
        fi
    
        systemctl enable haproxy
        systemctl restart haproxy
    fi

else
    echo "This script needs the \"ipcalc\" command line utility"
fi
