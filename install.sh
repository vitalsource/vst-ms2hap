#!/bin/bash
#set -x

PATH="/bin:/usr/bin:/usr/local/bin:/sbin:/usr/sbin:/usr/local/sbin:/opt/puppetlabs/puppet/bin:/snap/bin"
TERM="vt100"
export TERM PATH

gcs_bucket="${1}"
system_haproxy_config="/etc/haproxy/haproxy.cfg"
first_run_canary_file="/etc/ms2hapaga"

if [ -n "${gcs_bucket}" ]; then
    dont_stop="true"
    #needed_commands="facter gsutil jq"
    needed_commands="gsutil jq"

    for cmd_util in ${needed_commands} ; do
        key="my_${cmd_util}"
        value=$(which ${cmd_util} 2> /dev/null)

        if [ -n "${value}" ]; then
            eval "${key}=\"${value}\""
        else
            echo "ERROR:  Could not locate the command line utility '${cmd_util}'" >&2
            dont_stop="false"
        fi
        
    done

    # Grab the json file that corresponds to our GCP project
    if [ "${dont_stop}" = "true" ]; then
        #gcp_project=$(${my_facter} gce.project.projectId 2> /defv/null)
        gcp_project="vst-main-nonprod"

        if [ -n "${gcp_project}" ]; then
            cwd=$(pwd)
            temp_dir="$(mktemp -d)"
            target_file="${gcp_project}.json"
            cd "${temp_dir}"
            gsutil cp gs://${gcs_bucket}/${target_file} . > /dev/null 2>&1
            cd "${cwd}"

            let host_count=0
            let element_counter=0

            if [ -s "${temp_dir}/${target_file}"  ]; then
                this_host_count=$(${my_jq} ". | length" "${temp_dir}/${target_file}" 2> /dev/null)
                should_be_blank=$(echo "${this_host_count}" | sed -e 's|[0-9]||g')

                if [ -z "${should_be_blank}" ]; then
                    let host_count=${this_host_count}
                fi

            fi

            new_haproxy_config="/tmp/$$/haproxy.$(date +%Y%m%d).conf"

            while [ ${host_count} -gt 0 ]; do

                if [ ! -s "${new_haproxy_config}" ]; then
                    new_haproxy_config_dir=$(dirname "${new_haproxy_config}")

                    if [ ! -d "${new_haproxy_config_dir}" ]; then
                        mkdir -p "${new_haproxy_config_dir}"
                    fi

                    echo "Synthesizing haproxy config file '${new_haproxy_config}'"
                    awk '{print $0}' ./etc/haproxy/haproxy.conf.global    > "${new_haproxy_config}"
                    awk '{print $0}' ./etc/haproxy/haproxy.conf.defaults >> "${new_haproxy_config}"
                fi

                kv_pair=$(jq ".[${element_counter}]" "${temp_dir}/${target_file}" | egrep ':' | sed -e 's|"||g' -e 's| ||g')
                cms_internal_dns=$(echo "${kv_pair}" | awk -F':' '{print $1}' | awk -F'_' '{print $1}')
                cms_port=$(echo "${kv_pair}" | awk -F':' '{print $1}' | awk -F'_' '{print $NF}') 
                cms_name=$(echo "${kv_pair}" | awk -F':' '{print $NF}')
                normalized_cms_name=$(echo "${cms_name}" | sed -e 's|\.|_|g' -e 's|-|_|g')
                let proxy_port=${cms_port}+${element_counter}

                # Add the frontend for this node to the config file
                sed -e "s|{{NORMALIZED_CMS_NAME}}|${normalized_cms_name}|g" \
                    -e "s|{{PROXY_PORT}}|${proxy_port}|g"                   \
                ./etc/haproxy/haproxy.conf.frontend >> "${new_haproxy_config}"

                # Add the backend for this node to the config file
                sed -e "s|{{NORMALIZED_CMS_NAME}}|${normalized_cms_name}|g" \
                    -e "s|{{PROXY_PORT}}|${proxy_port}|g"                   \
                    -e "s|{{CMS_INTERNAL_DNS}}|${cms_internal_dns}|g"       \
                    -e "s|{{CMS_PORT}}|${cms_port}|g"                       \
                ./etc/haproxy/haproxy.conf.backend >> "${new_haproxy_config}"

                let element_counter+=1
                let host_count-=1
            done

            # Move the new conf file into position if differences are detected
            cmp -s "${new_haproxy_config}" "${system_haproxy_config}"

            if [ ${?} -gt 0 ]; then
                cp "${new_haproxy_config}" "${system_haproxy_config}"
                systemctl enable haproxy
                systemctl restart haproxy
            fi

        fi

        # The remaining setup - only run this once
        if [ ! -s "${first_run_canary_file}" ]; then
            echo "$(date)" > "${first_run_canary_file}"

            if [ -d ./etc ]; then
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
            
            fi
    
        fi

    fi

fi

