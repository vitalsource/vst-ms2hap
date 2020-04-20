#!/bin/bash
#set -x

PATH="/bin:/usr/bin:/usr/local/bin:/sbin:/usr/sbin:/usr/local/sbin:/opt/puppetlabs/puppet/bin:/snap/bin"
TERM="vt100"
export TERM PATH

system_haproxy_config="/etc/haproxy/haproxy.cfg"
first_run_canary_file="/etc/ms2hapaga"
etc_motd_dir="/etc/update-motd.d"
etc_motd_file="80-memorystore2redis"

my_script_dir="$(dirname $(realpath -L "${0}"))"
my_script_name=$(basename "${0}")

case "${my_script_name}" in

    update_ms2hap)
        gcs_bucket=$(awk '{print $NF}' "${first_run_canary_file}")
    ;;

    *)
        gcs_bucket="${1}"
    ;;

esac

# We must have a bucket from which to pull our json config
if [ -n "${gcs_bucket}" ]; then
    #needed_commands="gsutil jq"     ### TESTING
    needed_commands="facter gsutil jq"

    dont_stop="true"

    # Establish our commands that will be used later
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

    # Grab the json file that corresponds to our GCP project and GCP region
    if [ "${dont_stop}" = "true" ]; then
        this_os=$(uname -s | tr '[A-Z]' '[a-z]')

        #gcp_project="vst-main-nonprod"     ### TESTING
        #gcp_region="us-east1"              ### TESTING
        gcp_project=$(${my_facter} gce.project.projectId 2> /dev/null)
        gcp_region=$(${my_facter} gce.instance.zone 2> /dev/null | sed -e 's|\-[a-z]$||g')

        normalized_host_name=$(${my_facter} gce.instance.name 2> /dev/null)

        if [ -z "${normalized_host_name}" ]; then
            normalized_host_name=$(hostname | awk -F'.' '{print $1}')
        fi

        # Here we have computed our data driven resources and are ready to 
        # retrieve our GCP project and GCP region dependant json config file
        if [ -n "${gcp_project}" ]; then
            cwd=$(pwd)
            temp_dir="$(mktemp -d)"
            target_file="${gcp_project}-${gcp_region}.json"
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

            # Build the new haproxy config file from the config data
            new_haproxy_config="/tmp/$$/haproxy.$(date +%Y%m%d).conf"

            while [ ${host_count} -gt 0 ]; do

                if [ ! -s "${new_haproxy_config}" ]; then
                    new_haproxy_config_dir=$(dirname "${new_haproxy_config}")

                    if [ ! -d "${new_haproxy_config_dir}" ]; then
                        mkdir -p "${new_haproxy_config_dir}"
                    fi

                    echo "Synthesizing haproxy config file '${new_haproxy_config}'"
                    awk '{print $0}' ${my_script_dir}/etc/haproxy/haproxy.conf.global    > "${new_haproxy_config}"
                    awk '{print $0}' ${my_script_dir}/etc/haproxy/haproxy.conf.defaults >> "${new_haproxy_config}"
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
                ${my_script_dir}/etc/haproxy/haproxy.conf.frontend >> "${new_haproxy_config}"

                # Add the backend for this node to the config file
                sed -e "s|{{NORMALIZED_CMS_NAME}}|${normalized_cms_name}|g"   \
                    -e "s|{{NORMALIZED_HOST_NAME}}|${normalized_host_name}|g" \
                    -e "s|{{PROXY_PORT}}|${proxy_port}|g"                     \
                    -e "s|{{CMS_INTERNAL_DNS}}|${cms_internal_dns}|g"         \
                    -e "s|{{CMS_PORT}}|${cms_port}|g"                         \
                ${my_script_dir}/etc/haproxy/haproxy.conf.backend >> "${new_haproxy_config}"

                let element_counter+=1
                let host_count-=1
            done

            # Move the new conf file into position if differences are detected
            if [ "${this_os}" = "linux" -a -s "${new_haproxy_config}" ]; then
                cmp -s "${new_haproxy_config}" "${system_haproxy_config}"

                if [ ${?} -gt 0 ]; then
                    cp "${new_haproxy_config}" "${system_haproxy_config}"
                    systemctl enable haproxy
                    systemctl restart haproxy
                fi

            fi

        fi

        # The remaining setup - only run this once
        if [ ! -s "${first_run_canary_file}" -a "${this_os}" = "linux" ]; then
            echo "$(date) ${gcs_bucket}" > "${first_run_canary_file}"
            etc_cron_link="/etc/cron.daily/update_ms2hap"

            if [ ! -e "${etc_cron_link}" ]; then
                ln -s "${my_script_dir}/${my_script_name}" "${etc_cron_link}"
            fi

            if [ -d ./etc ]; then
                sysctl_conf="/etc/sysctl.conf"
                security_limits_conf="/etc/security/limits.conf"
                haproxy_conf="/etc/haproxy/haproxy.conf"
            
                if [ -f .${sysctl_conf} ]; then
                    awk '{print $0}' ${my_script_dir}${sysctl_conf} >> ${sysctl_conf}
                    sysctl -p
                fi
            
                if [ -e .${security_limits_conf} ]; then
                    awk '{print $0}' ${my_script_dir}${security_limits_conf} >> ${security_limits_conf}
                fi
            
            fi

            if [ ! -s "${etc_motd_dir}/${etc_motd_file}" ]; then
                cp ${my_script_dir}${etc_motd_dir}/${etc_motd_file} ${etc_motd_dir}
                chmod 755 ${etc_motd_dir}/${etc_motd_file}
            fi
    
        fi

    fi

fi

exit 0

