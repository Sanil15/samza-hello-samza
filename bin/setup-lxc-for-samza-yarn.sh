#!/bin/bash -e
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# This script will download, setup, start, and stop servers for Kafka, YARN, and ZooKeeper,
# as well as downloading, building and locally publishing Samza


COMMAND=$1
ARG0=$2
ARG1=$3

SHARED_LXC_DIR=/lxc-shared
POSSIBLE_LXC_INTERFACES=( virbr0 lxcbr0)
YARN_SITE_XML=conf/yarn-site.xml
NM_LIVENESS_MS=10000 #value of the yarn.nm.liveness-monitor.expiry-interval-ms variable
LXC_INSTANCE_TYPE="fedora"
LXC_ROOTFS_DIR=/var/lib/lxc
LXC_INSTANCE_START_NM_SCRIPT=startNodeManager

RESOLV_CONF_FILE=/etc/resolv.conf

# Helper function to test an IP address for validity:
# Usage:
#      valid_ip IP_ADDRESS
#      if [[ $? -eq 0 ]]; then echo good; else echo bad; fi
#   OR
#      if valid_ip IP_ADDRESS; then echo good; else echo bad; fi
#
function valid_ip()
{
    local  ip=$1
    local  stat=1

    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=($ip)
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
            && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
        stat=$?
    fi
    return $stat
}

function check_OS()
{
	#Check if OS is linux
	if [[ "$OSTYPE" == "linux-gnu" ]]; then
		echo "OS check passed."
	else
		echo "Only RHEL-Linux is currently supported for this setup. Exiting ..."
		exit 1
	fi
}


function setup_lxc()
{

	#Install LXC (and its dependencies)
	echo "Beginning installation. Installing LXC on your machine"
	sudo yum -y install epel-release
	sudo  yum -y install lxc lxc-templates libcap-devel libcgroup wget bridge-utils lxc-extra --skip-broken
	echo "LXC installation complete."


	lxc_interface=""
	gatewayIP=""

        for interface in ${POSSIBLE_LXC_INTERFACES[@]}
        do
                echo "Checking if $interface is valid"
                ip_address=`ip addr show $interface | grep "inet\b" | awk '{print $2}' | cut -d/ -f1`

                if valid_ip $ip_address; then
                        echo "Interface $interface is valid for using with LXC instances."
                        lxc_interface=$interface
                        gatewayIP=$ip_address
                        break;
                else
                        echo "Interface $interface does not appear to be valid."
                fi
        done

	if [[ -z "$lxc_interface" ]]; then
		echo "Did not find a valid network interface for use with LXC. Install LXC manually (https://linuxcontainers.org/lxc/getting-started/) and re-run."
		exit 1
	fi

	#Print the valid interface found
	echo "Using interface "$lxc_interface "($gatewayIP) for use with LXC"

	# Create shared directory for sharing between base machine and LXC-instances
	echo "Creating dir $SHARED_LXC_DIR to be shared between base machine and LXC-instances"
	sudo mkdir -p $SHARED_LXC_DIR && sudo chmod 777 $SHARED_LXC_DIR

	# Setting gateway IP address in conf/yarn-site.xml
	echo "Setting yarn.resourcemanager.hostname="$gatewayIP in $YARN_SITE_XML
	sed -i "/<name>yarn.resourcemanager.hostname<\/name>/!b;n;c<value>$gatewayIP</value>" $YARN_SITE_XML

	# Adding RM bind host in conf/yarn-site.xml
	echo "Setting yarn.resourcemanager.bind-host=0.0.0.0" in $YARN_SITE_XML
	if [[ ! -z $(grep "yarn.resourcemanager.bind-host" conf/yarn-site.xml) ]]; then

		# Setting yarn.resourcemanager.bind-host to 0.0.0.0
		sed -i "/<name>yarn.resourcemanager.bind-host<\/name>/!b;n;c<value>0.0.0.0</value>" $YARN_SITE_XML
	else

		# Appending RM bind host in conf/yarn-site.xml
		sed -i 's/<\/configuration>/<property>\n<name>yarn.resourcemanager.bind-host<\/name>\n<value>0.0.0.0<\/value>\n<\/property><\/configuration>/' $YARN_SITE_XML
	fi


	# Setting yarn.nm.liveness-monitor.expiry-interval-ms in  conf/yarn-site.xml
	echo "Setting yarn.nm.liveness-monitor.expiry-interval-ms=$NM_LIVENESS_MS" in $YARN_SITE_XML
	echo "Lowering default value for yarn.nm.liveness-monitor.expiry-interval-ms allows the RM to detect node-failures quickly"

	if [[ ! -z $(grep "yarn.nm.liveness-monitor.expiry-interval-ms" conf/yarn-site.xml) ]]; then

		# Setting yarn.nm.liveness-monitor.expiry-interval-ms
		sed -i "/<name>yarn.nm.liveness-monitor.expiry-interval-ms<\/name>/!b;n;c<value>$NM_LIVENESS_MS</value>" $YARN_SITE_XML
	else
		# Appending yarn.nm.liveness-monitor.expiry-interval-ms
		sed -i "s/<\/configuration>/<property>\n<name>yarn.nm.liveness-monitor.expiry-interval-ms<\/name>\n<value>$NM_LIVENESS_MS<\/value>\n<\/property><\/configuration>/" $YARN_SITE_XML
	fi

	# Adding gatewayIP to resolv.conf
	echo "Adding nameserver $gatewayIP to "$RESOLV_CONF_FILE
	NAMESERVER_LINE="nameserver $gatewayIP"
	grep -qF -- "$NAMESERVER_LINE" "$RESOLV_CONF_FILE" || sudo sed -i "1 s/^/nameserver $gatewayIP\n/" $RESOLV_CONF_FILE

}

function setup_lxc_instance()
{
	lxc_instance_name=$1
	instance_type=$2
	base_hostname=`hostname`
  fqdn_hostname=`hostname -f`

	# Creating lxc instance
	echo "Creating LXC instance with name "$lxc_instance_name
	sudo lxc-create -n $lxc_instance_name  -t $instance_type

	# Create a directory inside the container's filesystem for mounting /lxc-shared
	echo "Creating dir $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/lxc-shared inside $lxc_instance_name's filesystem"
	sudo mkdir -p $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/lxc-shared

	# Adding mount point for the shared-dir in the lxc-instance's config
	LINE="lxc.mount.entry = /lxc-shared $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/lxc-shared none bind 0 0"
	FILE="$LXC_ROOTFS_DIR/$lxc_instance_name/config"
	echo "Adding mount point for the shared-dir in the LXC-instance's config at $FILE"
	sudo grep -qF -- "$LINE" "$FILE" || sudo  echo "$LINE" | sudo tee -a "$FILE"

	echo "Finished creating lxc-instance "$lxc_instance_name

	echo "Copying this dir to lxc-instance "$lxc_instance_name at /$LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/root/samza-hello-world
	sudo cp -r . /$LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/root/samza-hello-world

	echo "Copying Java to lxc-instance "$lxc_instance_name at /$LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/root/java/
	sudo cp -r $JAVA_HOME /$LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/root/java/

  	# Adding line to /etc/hosts in lxc-instance
	LINE="$gatewayIP $base_hostname $fqdn_hostname"
	FILE="$LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/hosts"
	echo "Modifying LXC-instance's /etc/hosts. Adding $LINE to $FILE"
	sudo grep -qF -- "$LINE" "$FILE" || sudo  echo "$LINE" | sudo tee -a "$FILE"

	# Modifying /etc/hosts in lxc-instance
	echo "Removing localhost.localdomain from lxc-instance's /etc/hosts"
	sudo sed -i '/localhost.localdomain/d' $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/hosts

	echo "Removing localhost6.localdomain6 from lxc-instance's /etc/hosts"
	sudo sed -i '/localhost.localdomain/d' $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/hosts

	# Creating a script in /etc/init.d to start NM on lxc-instance start
	echo "Creating scripts to startup NodeManager on LXC-instance start"
	sudo echo "#!/bin/bash" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/rc.local
	sudo echo "export JAVA_HOME=/root/java" | sudo tee -a $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/rc.local
	sudo echo "sleep 5" | sudo tee -a $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/rc.local
	sudo echo "date >> /tmp/start.log" | sudo tee -a $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/rc.local
	sudo echo "/root/samza-hello-world/bin/grid start yarn_nm >> /tmp/start.log" | sudo tee -a $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/rc.local
	sudo echo "date >> /tmp/start.log" | sudo tee -a $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/rc.local
	sudo chmod +x $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/rc.local

	sudo echo "#!/bin/bash" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "[Unit]" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "Description=/etc/rc.local Compatibility" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "ConditionPathExists=/etc/rc.local" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "[Service]" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "Type=forking" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "ExecStart=/etc/rc.local start" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "TimeoutSec=0" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "StandardOutput=tty" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "RemainAfterExit=yes" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "SysVStartPriority=99" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "[Install]" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo echo "WantedBy=multi-user.target" | sudo tee -a  $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service

	sudo chmod +x $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service
	sudo cp $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/rc-local.service $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/systemd/system/multi-user.target.wants/rc-local.service

	sudo sed -i 's/.linkedin.biz//g' $LXC_ROOTFS_DIR/$lxc_instance_name/rootfs/etc/hostname
}

function setup_new_lxc_instance()
{
	check_OS
	setup_lxc
	local lxc_instance_name=$1
	setup_lxc_instance $lxc_instance_name $LXC_INSTANCE_TYPE
}

function setup_new_instance_from_img()
{
	desired_instance_name=$1

	check_OS
	setup_lxc

	FOLDER=yarn-lxc-samza
	URL=https://github.com/rmatharu/yarn-lxc-samza.git
	if [ ! -d "$FOLDER" ] ; then
		git clone $URL $FOLDER
	else
		cd "$FOLDER"
		git pull $URL
		cd ..
	fi

	sudo rm -rf $LXC_ROOTFS_DIR/lxc-yarn-img
	sudo rm -rf $LXC_ROOTFS_DIR/lxc-yarn-img-bk
	sudo cp -r yarn-lxc-samza/lxc-yarn-img-samza/ $LXC_ROOTFS_DIR/lxc-yarn-img-bk

	clone_lxc_instance lxc-yarn-img-bk $desired_instance_name

	echo "Default root password of "$desired_instance_name " is yarnLXC"

	echo "Checking if " $desired_instance_name " can be started ..."
	sudo lxc-start -d -n $desired_instance_name

	echo "Waiting for $desired_instance_name " to start
	while ! ping -c 1 -n -w 1 $desired_instance_name &> /dev/null
	do
	    echo -n "."
	done
	echo "Started."

	echo "Stopping..."
	sudo lxc-stop -n $desired_instance_name -t 10
	echo "$desired_instance_name Stopped"
	echo "To start "$desired_instance_name " use"
	echo "sudo lxc-start -d -n "$desired_instance_name
	echo
	echo "To stop "$desired_instance_name " use"
	echo "sudo lxc-stop -n "$desired_instance_name
	echo

}

function clone_lxc_instance()
{
	local original_container=$1
	local new_container=$2
	local base_hostname=`hostname`

	echo "Stopping container $original_container"
	sudo lxc-stop -n $original_container || true

	echo "Cloning $original_container to create $new_container"
	sudo lxc-clone $original_container $new_container

	containerConfig=`echo $LXC_ROOTFS_DIR/$new_container/config`

	echo "Container config: $containerConfig"
	echo "Setting mount directory in $containerConfig"
	sudo sed -i "s/$original_container/$new_container/g" $containerConfig

	echo "Creating mount dir in container img"
	sudo mkdir -p $LXC_ROOTFS_DIR/$new_container/rootfs/dev
	sudo mkdir -p $LXC_ROOTFS_DIR/$new_container/rootfs/proc
	sudo mkdir -p $LXC_ROOTFS_DIR/$new_container/rootfs/lxc-shared

	echo "Setting the right permissions in img"
	sudo chmod -R 600  $LXC_ROOTFS_DIR/$new_container/rootfs/etc/ssh/

	# Adding line to /etc/hosts in lxc-instance
	echo "IP of gateway on base machine is "$gatewayIP
        LINE="$gatewayIP $base_hostname $base_hostname"
        FILE="$LXC_ROOTFS_DIR/$new_container/rootfs/etc/hosts"
        echo "Modifying LXC-instance's /etc/hosts. Adding $LINE to $FILE"
        sudo grep -qF -- "$LINE" "$FILE" || sudo  echo "$LINE" | sudo tee -a "$FILE"

	echo
	echo "Finished creating container $new_container"
}

function check_if_already_exists()
{
	local lxc_instance_name=$1
	if [ -d "$LXC_ROOTFS_DIR/$lxc_instance_name" ]; then
		echo "LXC-instance "$lxc_instance_name "already exists. "
		echo "$ lxc-destroy -n "$lxc_instance_name
		echo "to delete the instance and retry."
		echo
		exit 1
	fi
}

if [[ "$COMMAND" == "create"  &&  ! -z "$ARG0" ]]; then
	check_if_already_exists $ARG0
	echo "Creating LXC instance $ARG0"
	setup_new_instance_from_img $ARG0

elif [[ "$COMMAND" == "clone"  &&  ! -z "$ARG0" && ! -z "$ARG1" ]]; then
	echo "Cloning LXC instance $ARG0 to create $ARG1"
	check_if_already_exists $ARG1
	clone_lxc_instance $ARG0 $ARG1

else
	echo
	echo "  This script is to be used with SAMZA with YARN."
	echo "  To use this script, first run"
	echo "  git clone https://github.com/apache/samza-hello-samza.git"
	echo "  git checkout latest"
	echo "  Copy this script to samza-hello-samza/bin, then run "
	echo "  bin/grid bootstrap"
	echo "  This will setup a local YARN cluster. Now use this script to add LXC instances as follows."
	echo
	echo "  Usage:"
	echo
	echo "  $ $0 create <LXC-instance-name> : Create a new LXC-instance with the given name."
	echo "  $ $0 clone <existing-LXC-instance-name> <new-LXC-instance-name> : Create a new LXC-instance by cloning an existing instance."
	echo
	exit 0
fi
