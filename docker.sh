#!/bin/bash

export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

chain_exists() {
    [ $# -lt 1 -o $# -gt 2 ] && {
        echo "Usage: chain_exists <chain_name> [table]" >&2
        return 1
    }
    local chain_name="$1" ; shift
    [ $# -eq 1 ] && local table="--table $1"
    /sbin/iptables $table -n --list "$chain_name" >/dev/null 2>&1
}

add_to_forward() {
    local docker_int=$1

    if [ `/sbin/iptables -nvL FORWARD | grep ${docker_int} | wc -l` -eq 0 ]; then
        /sbin/iptables -A FORWARD -o ${docker_int} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        /sbin/iptables -A FORWARD -o ${docker_int} -j DOCKER
        /sbin/iptables -A FORWARD -i ${docker_int} ! -o ${docker_int} -j ACCEPT
        /sbin/iptables -A FORWARD -i ${docker_int} -o ${docker_int} -j ACCEPT
    fi
}

add_to_nat() {
    local docker_int=$1
    local subnet=$2

    /sbin/iptables -t nat -A POSTROUTING -s ${subnet} ! -o ${docker_int} -j MASQUERADE
    /sbin/iptables -t nat -A DOCKER -i ${docker_int} -j RETURN
}

add_to_docker_isolation() {
    local docker_int=$1

    /sbin/iptables -A DOCKER-ISOLATION-STAGE-1 -i ${docker_int} ! -o ${docker_int} -j DOCKER-ISOLATION-STAGE-2
    /sbin/iptables -A DOCKER-ISOLATION-STAGE-2 -o ${docker_int} -j DROP
}

DOCKER_INT="docker0"
DOCKER_NETWORK="172.17.0.0/16"

/sbin/iptables-save | grep -v -- '-j DOCKER' | /sbin/iptables-restore
chain_exists DOCKER && /sbin/iptables -X DOCKER
chain_exists DOCKER nat && /sbin/iptables -t nat -X DOCKER

/sbin/iptables -N DOCKER
/sbin/iptables -N DOCKER-ISOLATION-STAGE-1
/sbin/iptables -N DOCKER-ISOLATION-STAGE-2
/sbin/iptables -N DOCKER-USER

/sbin/iptables -t nat -N DOCKER

/sbin/iptables -A FORWARD -j DOCKER-USER
/sbin/iptables -A FORWARD -j DOCKER-ISOLATION-STAGE-1
add_to_forward ${DOCKER_INT}

/sbin/iptables -t nat -A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
/sbin/iptables -t nat -A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER
/sbin/iptables -t nat -A POSTROUTING -s ${DOCKER_NETWORK} ! -o ${DOCKER_INT} -j MASQUERADE

bridges=`/usr/bin/docker network ls -q --filter='Driver=bridge'`

for bridge in $bridges; do
    DOCKER_NET_INT=`/usr/bin/docker network inspect -f '{{"'br-$bridge'" | or (index .Options "com.docker.network.bridge.name")}}' $bridge`
    subnet=`/usr/bin/docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' $bridge`

    add_to_nat ${DOCKER_NET_INT} ${subnet}
    add_to_forward ${DOCKER_NET_INT}
    add_to_docker_isolation ${DOCKER_NET_INT}
done

containers=`/usr/bin/docker ps -q`

if [ `echo ${containers} | wc -c` -gt "1" ]; then
    for container in ${containers}; do
        netmode=`/usr/bin/docker inspect -f "{{.HostConfig.NetworkMode}}" ${container}`
        if [ $netmode == "default" ]; then
            DOCKER_NET_INT=${DOCKER_INT}
            ipaddr=`/usr/bin/docker inspect -f "{{.NetworkSettings.IPAddress}}" ${container}`
        else
            bridge=$(/usr/bin/docker inspect -f "{{with index .NetworkSettings.Networks \"${netmode}\"}}{{.NetworkID}}{{end}}" ${container} | cut -c -12)
            DOCKER_NET_INT=`/usr/bin/docker network inspect -f '{{"'br-$bridge'" | or (index .Options "com.docker.network.bridge.name")}}' $bridge`
            ipaddr=`/usr/bin/docker inspect -f "{{with index .NetworkSettings.Networks \"${netmode}\"}}{{.IPAddress}}{{end}}" ${container}`
        fi

        rules=`/usr/bin/docker port ${container} | sed 's/ //g'`

        if [ `echo ${rules} | wc -c` -gt "1" ]; then
            for rule in ${rules}; do
                src=`echo '${rule}' | awk -F'->' '{ print $2 }'`
                dst=`echo '${rule}' | awk -F'->' '{ print $1 }'`

                src_ip=`echo '${src}' | awk -F':' '{ print $1 }'`
                src_port=`echo '${src}' | awk -F':' '{ print $2 }'`

                dst_port=`echo '${dst}' | awk -F'/' '{ print $1 }'`
                dst_proto=`echo '${dst}' | awk -F'/' '{ print $2 }'`

                /sbin/iptables -A DOCKER -d ${ipaddr}/32 ! -i ${DOCKER_NET_INT} -o ${DOCKER_NET_INT} -p ${dst_proto} -m ${dst_proto} --dport ${dst_port} -j ACCEPT

                /sbin/iptables -t nat -A POSTROUTING -s ${ipaddr}/32 -d ${ipaddr}/32 -p ${dst_proto} -m ${dst_proto} --dport ${dst_port} -j MASQUERADE

                iptables_opt_src=""
                if [ ${src_ip} != "0.0.0.0" ]; then
                    iptables_opt_src="-d ${src_ip}/32 "
                fi
                /sbin/iptables -t nat -A DOCKER ${iptables_opt_src}! -i ${DOCKER_NET_INT} -p ${dst_proto} -m ${dst_proto} --dport ${src_port} -j DNAT --to-destination ${ipaddr}:${dst_port}
            done
        fi
    done
fi

/sbin/iptables -A DOCKER-ISOLATION-STAGE-1 -j RETURN
/sbin/iptables -A DOCKER-ISOLATION-STAGE-2 -j RETURN
/sbin/iptables -A DOCKER-USER -j RETURN

if [ `/sbin/iptables -t nat -nvL DOCKER | grep ${DOCKER_INT} | wc -l` -eq 0 ]; then
    /sbin/iptables -t nat -I DOCKER -i ${DOCKER_INT} -j RETURN
fi
