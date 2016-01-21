#!/bin/bash

# devstack/plugin.sh
# Functions to install and configure Apache Kafka
#
# Dependencies:
#
#   - ``functions`` file
#
# ``stack.sh`` calls the entry points in this order:
#
#   - download_kafka
#   - install_kafka
#   - configure_kafka
#   - init_kafka
#   - stop_kafka
#   - cleanup_kafka

# Save trace setting
XTRACE=$(set +o | grep xtrace)
set +o xtrace

# Functions
# ------------
# download_kafka() - downloading kafka
function download_kafka {
    if [ ! -f ${FILES}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz ]; then
        wget ${KAFKA_BASEURL}/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz \
            -O ${FILES}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz
    fi
}

# install_kafka() - installing Kafka with Scala and Zookeeper
function install_kafka {

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

    download_kafka

    if [ ! -d ${FILES}/kafka_${SCALA_VERSION}-${KAFKA_VERSION} ]; then
        tar -xvzf ${FILES}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz -C ${FILES}
    fi
    if [ ! -d ${KAFKA_DEST}/kafka ]; then
        mkdir -p ${KAFKA_DEST}
        mv ${FILES}/kafka_${SCALA_VERSION}-${KAFKA_VERSION} ${KAFKA_DEST}/kafka
    fi
}

# init_kafka() - starting Kafka and Zookeeper processes
function init_kafka {
    # start Zookeeper process before starting Kafka
    ${KAFKA_DEST}/kafka/bin/zookeeper-server-start.sh -daemon ${KAFKA_DEST}/kafka/config/zookeeper.properties
    ${KAFKA_DEST}/kafka/bin/kafka-server-start.sh -daemon ${KAFKA_DEST}/kafka/config/server.properties
}

# configure_kafka() - configuring Kafka service
function configure_kafka {
    # currently a no op
    :
}

# stop_kafka() - stopping Kafka process
function stop_kafka {
    ${KAFKA_DEST}/kafka/bin/kafka-server-stop.sh
    ${KAFKA_DEST}/kafka/bin/zookeeper-server-stop.sh
}

# cleanup_kafka() - removing Kafka files
# make sure this function is called only after calling stop_kafka() function
function cleanup_kafka {
    rm ${FILES}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz
    rm -rf ${KAFKA_DEST}/kafka
}

# check for kafka service
if is_service_enabled devstack-plugin-kafka; then
    if [[ "$1" == "source" ]]; then
        # Initial source
        source $TOP_DIR/lib/kafka

    elif [[ "$1" == "stack" && "$2" == "install" ]]; then
        # Perform installation of service source
        echo_summary "Installing kafka"
        install_kafka

        echo_summary "Initializing kafka"
        init_kafka

    elif [[ "$1" == "unstack" ]]; then
        # Shut down kafka services
        echo_summary "Shut down kafka service"
        stop_kafka

    elif [[ "$1" == "clean" ]]; then
        # Remove state and transient data
        # Remember clean.sh first calls unstack.sh
        echo_summary "Clean up kafka service"
        cleanup_kafka
    fi
fi

# Restore xtrace
$XTRACE

## Local variables:
## mode: shell-script
## End:
