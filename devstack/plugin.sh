#!/bin/bash
#
#    Licensed to the Apache Software Foundation (ASF) under one
#    or more contributor license agreements.  See the NOTICE file
#    distributed with this work for additional information
#    regarding copyright ownership.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
#

# Install and configure Apache Kafka. Since kafka is only used for
# oslo.messaging notifications, setup a hybrid messaging backend.
# The RPC transport backend will be amqp:// and the
# Notification transport wil be kafka://
#
# Environment Configuration
# RPC_HOST - the host used to connect to the RPC messaging service.
# RPC_PORT - the port used to connect to the RPC messaging service.
#     Defaults to 5672.
# RPC_{USERNAME,PASSWORD} - for authentication with RPC messaging service.
# NOTIFY_HOST - the host used to connect to the Notification messaging service.
# NOTIFY_PORT - the port used to connect to the Notification messaging service.
#     Defaults to 9092.
# NOTIFY_{USERNAME,PASSWORD} - for authentication with Notification messaging
#     service.

# Save trace setting
XTRACE=$(set +o | grep xtrace)
set +o xtrace

# builds rpc transport url string
function _get_rpc_transport_url {
    if [ -z "$RPC_USERNAME" ]; then
        echo "amqp://$RPC_HOST:${RPC_PORT}/"
    else
        echo "amqp://$RPC_USERNAME:$RPC_PASSWORD@$RPC_HOST:${RPC_PORT}/"
    fi
}

# builds notify transport url string
function _get_notify_transport_url {
    if [ -z "$NOTIFY_USERNAME" ]; then
        echo "kafka://$NOTIFY_HOST:${NOTIFY_PORT}/"
    else
        echo "kafka://$NOTIFY_USERNAME:$NOTIFY_PASSWORD@$NOTIFY_HOST:${NOTIFY_PORT}/"
    fi
}

# Functions
# ------------
# _download_kafka() - downloading kafka
function _download_kafka {
    if [ ! -f ${FILES}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz ]; then
        wget ${KAFKA_BASEURL}/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz \
            -O ${FILES}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz
    fi
}

# install packages necessary for support of the oslo.messaging kafka
# driver
function _install_kafka_python {
    # Install kafka client API
    pip_install_gr kafka-python
}

# _install_kafka_backend() - installing Kafka with Scala and Zookeeper
function _install_kafka_backend {
    echo_summary "Installing kafka service"
    local scala_version=${SCALA_VERSION}.0

    if is_ubuntu; then
        sudo apt-get install -y scala
    elif is_fedora; then

        is_package_installed java-1.8.0-openjdk-headless || install_package java-1.8.0-openjdk-headless

        if [ ! -f ${FILES}/scala-${scala_version}.tar.gz ]; then
            wget ${SCALA_BASEURL}/scala-${scala_version}.tgz \
                -O ${FILES}/scala-${scala_version}.tar.gz
        fi

        if [ ! -d ${FILES}/scala-${scala_version} ]; then
            tar -xvzf ${FILES}/scala-${scala_version}.tar.gz -C ${FILES}
        fi

        if [ ! -d /usr/lib/scala-${scala_version} ]; then
            sudo mv ${FILES}/scala-${scala_version} /usr/lib
            sudo ln -s /usr/lib/scala-${scala_version} /usr/lib/scala
            export PATH=$PATH:/usr/lib/scala/bin
        fi
    fi

    _download_kafka

    if [ ! -d ${FILES}/kafka_${SCALA_VERSION}-${KAFKA_VERSION} ]; then
        tar -xvzf ${FILES}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz -C ${FILES}
    fi
    if [ ! -d ${KAFKA_DEST}/kafka ]; then
        mkdir -p ${KAFKA_DEST}
        mv ${FILES}/kafka_${SCALA_VERSION}-${KAFKA_VERSION} ${KAFKA_DEST}/kafka
    fi

    _install_kafka_python
}

# _start_kafka_backend() - starting Kafka and Zookeeper processes
function _start_kafka_backend {
    # start Zookeeper process before starting Kafka
    echo_summary "Initializing and starting kafka service"
    ${KAFKA_DEST}/kafka/bin/zookeeper-server-start.sh -daemon ${KAFKA_DEST}/kafka/config/zookeeper.properties
    ${KAFKA_DEST}/kafka/bin/kafka-server-start.sh -daemon ${KAFKA_DEST}/kafka/config/server.properties
}

# _configure_kafka() - configuring Kafka service
function _configure_kafka {
    # currently a no op
    :
}

# _stop_kafka() - stopping Kafka process
function _stop_kafka {
    echo_summary "Shut down kafka service"
    ${KAFKA_DEST}/kafka/bin/kafka-server-stop.sh
    ${KAFKA_DEST}/kafka/bin/zookeeper-server-stop.sh
}

# _cleanup_kafka() - removing Kafka files
# make sure this function is called only after calling stop_kafka() function
function _cleanup_kafka {
    echo_summary "Clean up kafka service"
    rm ${FILES}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz
    rm -rf ${KAFKA_DEST}/kafka
}

# Set up the various configuration files used by the qpid-dispatch-router (qdr)
function _configure_qdr {

    # the location of the configuration is /etc/qpid-dispatch
    local qdr_conf_file
    if [ -e /etc/qpid-dispatch/qdrouterd.conf ]; then
        qdr_conf_file=/etc/qpid-dispatch/qdrouterd.conf
    else
        exit_distro_not_supported "qdrouterd.conf file not found!"
    fi

    # ensure that the qpid-dispatch-router service can read its config
    sudo chmod o+r $qdr_conf_file

    # qdouterd.conf file customization for devstack deployment
    # Define attributes related to the AMQP container
    # Create stand alone router
    cat <<EOF | sudo tee $qdr_conf_file
router {
    mode: standalone
    id: Router.A
    workerThreads: 4
    saslConfigPath: /etc/sasl2
    saslConfigName: qdrouterd
    debugDump: /opt/stack/amqp1
}

EOF

    # Create a listener for incoming connect to the router
    cat <<EOF | sudo tee --append $qdr_conf_file
listener {
    addr: 0.0.0.0
    port: ${RPC_PORT}
    role: normal
EOF
    if [ -z "$RPC_USERNAME" ]; then
        #no user configured, so disable authentication
        cat <<EOF | sudo tee --append $qdr_conf_file
    authenticatePeer: no
}

EOF
    else
        # configure to use PLAIN authentication
        if [ -z "$RPC_PASSWORD" ]; then
            read_password RPC_PASSWORD "ENTER A PASSWORD FOR QPID DISPATCH USER $RPC_USERNAME"
        fi
        cat <<EOF | sudo tee --append $qdr_conf_file
    authenticatePeer: yes
}

EOF
        # Add user to SASL database
        local sasl_conf_file=/etc/sasl2/qdrouterd.conf
        cat <<EOF | sudo tee $sasl_conf_file
pwcheck_method: auxprop
auxprop_plugin: sasldb
sasldb_path: /var/lib/qdrouterd/qdrouterd.sasldb
mech_list: PLAIN
sql_select: dummy select
EOF
        local sasl_db
        sasl_db=`sudo grep sasldb_path $sasl_conf_file | cut -f 2 -d ":" | tr -d [:blank:]`
        if [ ! -e $sasl_db ]; then
            sudo mkdir -p -m 755 `dirname $sasl_db`
        fi
        echo $RPC_PASSWORD | sudo saslpasswd2 -c -p -f $sasl_db $RPC_USERNAME
        sudo chmod o+r $sasl_db
    fi

    # Create fixed address prefixes
    cat <<EOF | sudo tee --append $qdr_conf_file
address {
    prefix: unicast
    distribution: closest
}

address {
    prefix: exclusive
    distribution: closest
}

address {
    prefix: broadcast
    distribution: multicast
}

address {
    prefix: openstack.org/om/rpc/multicast
    distribution: multicast
}

address {
    prefix: openstack.org/om/rpc/unicast
    distribution: closest
}

address {
    prefix: openstack.org/om/rpc/anycast
    distribution: balanced
}

address {
    prefix: openstack.org/om/notify/multicast
    distribution: multicast
}

address {
    prefix: openstack.org/om/notify/unicast
    distribution: closest
}

address {
    prefix: openstack.org/om/notify/anycast
    distribution: balanced
}

EOF

    local log_file=$LOGDIR/qdrouterd.log

    sudo touch $log_file
    sudo chmod a+rw $log_file  # qdrouterd user can write to it

    # Create log file configuration
    cat <<EOF | sudo tee --append $qdr_conf_file
log {
    module: DEFAULT
    enable: info+
    output: $log_file
}

EOF

}

# install packages necessary for support of the oslo.messaging AMQP
# 1.0 driver
function _install_pyngus {
    # Install pyngus client API
    if is_fedora; then
        # TODO(kgiusti) due to a bug in the way pip installs wheels,
        # do not let pip install the proton python bindings as it will
        # put them in the wrong path:
        # https://github.com/pypa/pip/issues/2940
        install_package python-qpid-proton
    elif is_ubuntu; then
        # ditto
        install_package python-qpid-proton
    fi
    pip_install_gr pyngus
}

# install and configure the amqp1 backend
# dispatch-router for hybrid deployment with kakfa
function _install_qdr_backend {
    echo_summary "Installing amqp1 service qdrouterd"
    if is_fedora; then
        # expects epel is already added to the yum repos
        install_package cyrus-sasl-lib
        install_package cyrus-sasl-plain
        install_package qpid-dispatch-router
    elif is_ubuntu; then
        install_package sasl2-bin
        # qdrouterd and proton only available via the qpid PPA
        sudo add-apt-repository -y ppa:qpid/released
        #sudo apt-get update
        REPOS_UPDATED=False
        update_package_repo
        install_package qdrouterd
    else
        exit_distro_not_supported "amqp1 qdrouterd installation"
    fi

    _install_pyngus
    _configure_qdr
}

function _start_qdr_backend {
    echo_summary "Starting qdrouterd backend"
    # restart, since qdrouterd may already be running
    restart_service qdrouterd
}

function _stop_qdr_backend {
    echo_summary "Stopping qdrouterd backend"
    stop_service qdrouterd
}

# remove packages used by oslo.messaging AMQP 1.0 driver
function _remove_pyngus {
    # TODO(ansmith) no way to pip uninstall?
    # pip_install_gr pyngus
    :
}

function _cleanup_qdr_backend {
    if is_fedora; then
        uninstall_package qpid-dispatch-router
        # TODO(ansmith) can we pull these, or will that break other
        # packages that depend on them?

        # install_package cyrus_sasl_lib
        # install_package cyrus_sasl_plain
    elif is_ubuntu; then
        uninstall_package qdrouterd
        # install_package sasl2-bin
    else
        exit_distro_not_supported "amqp1 qdrouterd installation"
    fi

    _remove_pyngus
}

if is_service_enabled kafka; then

    # Note: this is the only tricky part about out of tree
    # oslo.messaging plugins, you must overwrite the functions
    # so that the correct settings files are made.
    function iniset_rpc_backend {
        local package=$1
        local file=$2
        local section=${3:-DEFAULT}
        iniset $file $section transport_url $(_get_rpc_transport_url)
        iniset $file oslo_messaging_notifications transport_url $(_get_notify_transport_url)
    }
    function get_transport_url {
        # TODO (ansmith) introduce separate get_*_transport calls in devstak
        _get_rpc_transport_url $@
    }
    function get_notification_url {
        _get_notify_transport_url $@
    }
    export -f iniset_rpc_backend
    export -f get_transport_url
    export -f get_notification_url
fi

# check for kafka service
if is_service_enabled kafka; then
    if [[ "$1" == "source" ]]; then
        # Initial source
        source $TOP_DIR/lib/kafka

    elif [[ "$1" == "stack" && "$2" == "pre-install" ]]; then
        # nothing needed here
        :

    elif [[ "$1" == "stack" && "$2" == "install" ]]; then
        # Install and configure the messaging services
        _install_kafka_backend
        _install_qdr_backend

    elif [[ "$1" == "stack" && "$2" == "post-config" ]]; then
        # Start the messaging service processes, this happens before
        # any services start
        _start_kafka_backend
        _start_qdr_backend

    elif [[ "$1" == "unstack" ]]; then
        # Shut down messaging services
        _stop_kafka
        _stop_qdr

    elif [[ "$1" == "clean" ]]; then
        # Remove state and transient data
        # Remember clean.sh first calls unstack.sh
        _cleanup_kafka
        _cleanup_qdr
    fi
fi

# Restore xtrace
$XTRACE

## Local variables:
## mode: shell-script
## End:
