#!/bin/bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS-IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script installs NVIDIA GPU drivers (version 535.104.05) along with CUDA 12.2.
# However, Cuda 12.1.1 - Driver v530.30.02 is used for Ubuntu 18 only
# Additionally, it installs the RAPIDS Spark plugin, configures Spark and YARN, and is compatible with Debian, Ubuntu, and Rocky Linux distributions.
# Note that the script is designed to work when secure boot is disabled during cluster creation.
# It also creates a Systemd Service for maintaining up-to-date Kernel Headers on Debian and Ubuntu.

set -euxo pipefail

function get_metadata_attribute() {
  local -r attribute_name=$1
  local -r default_value=$2
  /usr/share/google/get_metadata_value "attributes/${attribute_name}" || echo -n "${default_value}"
}

# Fetch Linux Family distro and Dataproc Image version
readonly OS_NAME=$(lsb_release -is | tr '[:upper:]' '[:lower:]')
readonly DATAPROC_IMAGE_VERSION=$(/usr/share/google/get_metadata_value image|grep -Eo 'dataproc-[0-9]-[0-9]'|grep -Eo '[0-9]-[0-9]'|sed -e 's/-/./g')

# Fetch SPARK config
readonly SPARK_VERSION_ENV=$(spark-submit --version 2>&1 | sed -n 's/.*version[[:blank:]]\+\([0-9]\+\.[0-9]\).*/\1/p' | head -n1)
if [[ "${SPARK_VERSION_ENV}" == "3"* ]]; then
  readonly DEFAULT_XGBOOST_VERSION="1.7.6"
  readonly SPARK_VERSION="3.0"
else
  echo "Error: Your Spark version is not supported. Please upgrade Spark to one of the supported versions."
  exit 1
fi

# Update SPARK RAPIDS config
readonly DEFAULT_SPARK_RAPIDS_VERSION="24.02.0"
readonly SPARK_RAPIDS_VERSION=$(get_metadata_attribute 'spark-rapids-version' ${DEFAULT_SPARK_RAPIDS_VERSION})
readonly XGBOOST_VERSION=$(get_metadata_attribute 'xgboost-version' ${DEFAULT_XGBOOST_VERSION})

# Fetch instance roles and runtime
readonly ROLE=$(/usr/share/google/get_metadata_value attributes/dataproc-role)
readonly MASTER=$(/usr/share/google/get_metadata_value attributes/dataproc-master)
readonly RUNTIME=$(get_metadata_attribute 'rapids-runtime' 'SPARK')

# CUDA version and Driver version config
CUDA_VERSION=$(get_metadata_attribute 'cuda-version' '12.2.2')  #12.2.2
NVIDIA_DRIVER_VERSION=$(get_metadata_attribute 'driver-version' '535.104.05') #535.104.05
CUDA_VERSION_MAJOR="${CUDA_VERSION%.*}"  #12.2

# EXCEPTIONS
# Change CUDA version for Ubuntu 18 (Cuda 12.1.1 - Driver v530.30.02 is the latest version supported by Ubuntu 18)
if [[ "${OS_NAME}" == "ubuntu" ]]; then
    UBUNTU_VERSION=$(lsb_release -r | awk '{print $2}') # 20.04
    UBUNTU_VERSION=${UBUNTU_VERSION%.*}
    if [[ "${UBUNTU_VERSION}" == "18" ]]; then
      CUDA_VERSION=$(get_metadata_attribute 'cuda-version' '12.1.1')  #12.1.1
      NVIDIA_DRIVER_VERSION=$(get_metadata_attribute 'driver-version' '530.30.02') #530.30.02
      CUDA_VERSION_MAJOR="${CUDA_VERSION%.*}"  #12.1
    fi
fi
# Change CUDA version for Debian 12 (Cuda 12.3.2 - Driver v545.23.08 is the latest version supported by Debian 12)
if [[ "${OS_NAME}" == "debian" ]]; then
    DEBIAN_VERSION=$(lsb_release -r | awk '{print $2}') # 12
    if [[ "${DEBIAN_VERSION}" == "12" ]]; then
      CUDA_VERSION=$(get_metadata_attribute 'cuda-version' '12.3.2')  #12.3.2
      NVIDIA_DRIVER_VERSION=$(get_metadata_attribute 'driver-version' '545.23.08') #545.23.08
      CUDA_VERSION_MAJOR="${CUDA_VERSION%.*}"  #12.3
    fi
fi

# CUDA version and Driver version
# https://docs.nvidia.com/deeplearning/frameworks/support-matrix/index.html
readonly -A DRIVER_FOR_CUDA=([10.1]="418.88"    [10.2]="440.64.00"
          [11.0]="450.51.06" [11.1]="455.45.01" [11.2]="460.73.01"
          [11.5]="495.29.05" [11.6]="510.47.03" [11.7]="515.65.01"
          [11.8]="520.56.06")
readonly -A CUDNN_FOR_CUDA=( [10.1]="7.6.4.38"  [10.2]="7.6.5.32"
          [11.0]="8.0.4.30"  [11.1]="8.0.5.39"  [11.2]="8.1.1.33"
          [11.5]="8.3.3.40"  [11.6]="8.4.1.50"  [11.7]="8.5.0.96"
          [11.8]="8.6.0.163")
readonly -A NCCL_FOR_CUDA=(  [10.1]="2.4.8"     [10.2]="2.5.6"
          [11.0]="2.7.8"     [11.1]="2.8.3"     [11.2]="2.8.3"
          [11.5]="2.11.4"    [11.6]="2.11.4"    [11.7]="2.12.12"
          [11.8]="2.15.5")
readonly -A CUDA_SUBVER=(    [10.1]="10.1.243"  [10.2]="10.2.89"
          [11.0]="11.0.3"    [11.1]="11.1.0"    [11.2]="11.2.2"
          [11.5]="11.5.2"    [11.6]="11.6.2"    [11.7]="11.7.1"
          [11.8]="11.8.0")


readonly DEFAULT_NVIDIA_DEBIAN_GPU_DRIVER_VERSION=${DRIVER_FOR_CUDA["${CUDA_VERSION_MAJOR}"]}
readonly NVIDIA_DEBIAN_GPU_DRIVER_VERSION=$(get_metadata_attribute 'gpu-driver-version' ${DEFAULT_NVIDIA_DEBIAN_GPU_DRIVER_VERSION})
readonly NVIDIA_DEBIAN_GPU_DRIVER_VERSION_PREFIX=${NVIDIA_DEBIAN_GPU_DRIVER_VERSION%%.*}

#Parameters for NVIDIA-provided Debian GPU driver
DEFAULT_NVIDIA_DEBIAN_GPU_DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_DEBIAN_GPU_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DEBIAN_GPU_DRIVER_VERSION}.run"
if [[ "$(curl -s -I ${DEFAULT_NVIDIA_DEBIAN_GPU_DRIVER_URL} | head -1 | awk '{print $2}')" != "200" ]]; then
  DEFAULT_NVIDIA_DEBIAN_GPU_DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_DEBIAN_GPU_DRIVER_VERSION%.*}/NVIDIA-Linux-x86_64-${NVIDIA_DEBIAN_GPU_DRIVER_VERSION%.*}.run"
fi
readonly DEFAULT_NVIDIA_DEBIAN_GPU_DRIVER_URL

NVIDIA_DEBIAN_GPU_DRIVER_URL=$(get_metadata_attribute 'gpu-driver-url' "${DEFAULT_NVIDIA_DEBIAN_GPU_DRIVER_URL}")
readonly NVIDIA_DEBIAN_GPU_DRIVER_URL

readonly NVIDIA_BASE_DL_URL='https://developer.download.nvidia.com/compute'


readonly NVIDIA_UBUNTU_REPO_URL="${NVIDIA_BASE_DL_URL}/cuda/repos/ubuntu1804/x86_64"
readonly NVIDIA_UBUNTU_REPO_KEY_PACKAGE="${NVIDIA_UBUNTU_REPO_URL}/cuda-keyring_1.0-1_all.deb"
readonly NVIDIA_UBUNTU_REPO_CUDA_PIN="${NVIDIA_UBUNTU_REPO_URL}/cuda-ubuntu1804.pin"

readonly -A DEFAULT_NVIDIA_DEBIAN_CUDA_URLS=(
  [10.1]="${NVIDIA_BASE_DL_URL}/cuda/10.1/Prod/local_installers/cuda_10.1.243_418.87.00_linux.run"
  [10.2]="${NVIDIA_BASE_DL_URL}/cuda/10.2/Prod/local_installers/cuda_10.2.89_440.33.01_linux.run"
  [11.0]="${NVIDIA_BASE_DL_URL}/cuda/11.0.3/local_installers/cuda_11.0.3_450.51.06_linux.run"
  [11.1]="${NVIDIA_BASE_DL_URL}/cuda/11.1.0/local_installers/cuda_11.1.0_455.23.05_linux.run"
  [11.2]="${NVIDIA_BASE_DL_URL}/cuda/11.2.2/local_installers/cuda_11.2.2_460.32.03_linux.run"
  [11.5]="${NVIDIA_BASE_DL_URL}/cuda/11.5.2/local_installers/cuda_11.5.2_495.29.05_linux.run"
  [11.6]="${NVIDIA_BASE_DL_URL}/cuda/11.6.2/local_installers/cuda_11.6.2_510.47.03_linux.run"
  [11.7]="${NVIDIA_BASE_DL_URL}/cuda/11.7.1/local_installers/cuda_11.7.1_515.65.01_linux.run"
  [11.8]="${NVIDIA_BASE_DL_URL}/cuda/11.8.0/local_installers/cuda_11.8.0_520.61.05_linux.run")
readonly DEFAULT_NVIDIA_DEBIAN_CUDA_URL=${DEFAULT_NVIDIA_DEBIAN_CUDA_URLS["${CUDA_VERSION_MAJOR}"]}
NVIDIA_DEBIAN_CUDA_URL=$(get_metadata_attribute 'cuda-url' "${DEFAULT_NVIDIA_DEBIAN_CUDA_URL}")
readonly NVIDIA_DEBIAN_CUDA_URL

# Verify Secure boot
SECURE_BOOT="disabled"
SECURE_BOOT=$(mokutil --sb-state|awk '{print $2}')

# Stackdriver GPU agent parameters
# Whether to install GPU monitoring agent that sends GPU metrics to Stackdriver
INSTALL_GPU_AGENT=$(get_metadata_attribute 'install-gpu-agent' 'false')
readonly INSTALL_GPU_AGENT

# Dataproc configurations
readonly HADOOP_CONF_DIR='/etc/hadoop/conf'
readonly HIVE_CONF_DIR='/etc/hive/conf'
readonly SPARK_CONF_DIR='/etc/spark/conf'

NVIDIA_SMI_PATH='/usr/bin'
MIG_MAJOR_CAPS=0
IS_MIG_ENABLED=0

function execute_with_retries() {
  local -r cmd=$1
  for ((i = 0; i < 10; i++)); do
    if eval "$cmd"; then
      return 0
    fi
    sleep 5
  done
  return 1
}

function install_spark_rapids() {
  local -r rapids_repo_url='https://repo1.maven.org/maven2/ai/rapids'
  local -r nvidia_repo_url='https://repo1.maven.org/maven2/com/nvidia'
  local -r dmlc_repo_url='https://repo.maven.apache.org/maven2/ml/dmlc'

  wget -nv --timeout=120 --tries=5 --retry-connrefused \
    "${dmlc_repo_url}/xgboost4j-spark-gpu_2.12/${XGBOOST_VERSION}/xgboost4j-spark-gpu_2.12-${XGBOOST_VERSION}.jar" \
    -P /usr/lib/spark/jars/

  wget -nv --timeout=120 --tries=5 --retry-connrefused \
    "${dmlc_repo_url}/xgboost4j-gpu_2.12/${XGBOOST_VERSION}/xgboost4j-gpu_2.12-${XGBOOST_VERSION}.jar" \
    -P /usr/lib/spark/jars/


  wget -nv --timeout=120 --tries=5 --retry-connrefused \
    "${nvidia_repo_url}/rapids-4-spark_2.12/${SPARK_RAPIDS_VERSION}/rapids-4-spark_2.12-${SPARK_RAPIDS_VERSION}.jar" \
    -P /usr/lib/spark/jars/

  # gsutil cp -vn gs://vidio-bigdata-prod/dataproc/initialization/rapids/xgboost4j-spark-gpu_2.12-${XGBOOST_VERSION}.jar /usr/lib/spark/jars/
  # gsutil cp -vn gs://vidio-bigdata-prod/dataproc/initialization/rapids/xgboost4j-gpu_2.12-${XGBOOST_VERSION}.jar /usr/lib/spark/jars/
  # gsutil cp -vn gs://vidio-bigdata-prod/dataproc/initialization/rapids/rapids-4-spark_2.12-${SPARK_RAPIDS_VERSION}.jar /usr/lib/spark/jars/
}

function configure_spark() {
  if [[ "${SPARK_VERSION}" == "3"* ]]; then
    cat >>${SPARK_CONF_DIR}/spark-defaults.conf <<EOF

###### BEGIN : RAPIDS properties for Spark ${SPARK_VERSION} ######
# Rapids Accelerator for Spark can utilize AQE, but when the plan is not finalized,
# query explain output won't show GPU operator, if user have doubt
# they can uncomment the line before seeing the GPU plan explain, but AQE on gives user the best performance.
spark.executor.resource.gpu.amount=1
spark.plugins=com.nvidia.spark.SQLPlugin
spark.executor.resource.gpu.discoveryScript=/usr/lib/spark/scripts/gpu/getGpusResources.sh
spark.dynamicAllocation.enabled=false
spark.sql.autoBroadcastJoinThreshold=10m
spark.sql.files.maxPartitionBytes=512m
# please update this config according to your application
spark.task.resource.gpu.amount=0.25
spark.kryo.registrator=com.nvidia.spark.rapids.GpuKryoRegistrator
###### END   : RAPIDS properties for Spark ${SPARK_VERSION} ######
EOF
  else
    cat >>${SPARK_CONF_DIR}/spark-defaults.conf <<EOF

###### BEGIN : RAPIDS properties for Spark ${SPARK_VERSION} ######
spark.submit.pyFiles=/usr/lib/spark/jars/xgboost4j-spark_${SPARK_VERSION}-${XGBOOST_VERSION}-${XGBOOST_GPU_SUB_VERSION}.jar
###### END   : RAPIDS properties for Spark ${SPARK_VERSION} ######
EOF
  fi
}

# Enables a systemd service on bootup to install new headers.
# This service recompiles kernel modules for Ubuntu and Debian, which are necessary for the functioning of nvidia-smi.
function setup_systemd_update_headers() {
  cat <<EOF >/lib/systemd/system/install-headers.service
[Unit]
Description=Install Linux headers for the current kernel
After=network-online.target

[Service]
ExecStart=/bin/bash -c 'count=0; while [ \$count -lt 3 ]; do /usr/bin/apt-get install -y -q linux-headers-\$(/bin/uname -r) && break; count=\$((count+1)); sleep 5; done'
Type=oneshot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  # Reload systemd to recognize the new unit file
  systemctl daemon-reload

  # Enable and start the service
  systemctl enable --now install-headers.service
}


# Install NVIDIA GPU driver provided by NVIDIA
function install_nvidia_gpu_driver() {

  ## common steps for all linux family distros
  readonly NVIDIA_DRIVER_VERSION_PREFIX=${NVIDIA_DRIVER_VERSION%%.*}

  ## installation steps based OS_NAME
  if [[ ${OS_NAME} == "debian" ]]; then

    DEBIAN_VERSION=$(lsb_release -r|awk '{print $2}') # 10 or 11
    export DEBIAN_FRONTEND=noninteractive

    execute_with_retries "apt-get install -y -q 'linux-headers-$(uname -r)'"

    # readonly LOCAL_INSTALLER_DEB="cuda-repo-ubuntu1804-${CUDA_VERSION_MAJOR//./-}-local_${CUDA_VERSION}-${NVIDIA_DRIVER_VERSION}-1_amd64.deb"
    # curl -fsSL --retry-connrefused --retry 3 --retry-max-time 5 \
    #   "https://developer.download.nvidia.com/compute/cuda/${CUDA_VERSION}/local_installers/${LOCAL_INSTALLER_DEB}" -o /tmp/local-installer.deb
    #
    # dpkg -i /tmp/local-installer.deb
    # cp /var/cuda-repo-ubuntu1804-${CUDA_VERSION_MAJOR//./-}-local/cuda-*-keyring.gpg /usr/share/keyrings/

    ## EXCEPTION
    if [[ ${DEBIAN_VERSION} == 12 ]]; then
      sed -i '0,/Components: main/s//& contrib/' /etc/apt/sources.list.d/debian.sources
    fi

    add-apt-repository contrib
    execute_with_retries "apt-get update"

    ## EXCEPTION
    if [[ ${DEBIAN_VERSION} == 10 ]]; then
      apt remove -y libglvnd0
      apt install -y ca-certificates-java
    fi

    ## EXCEPTION
    # if [[ ${DEBIAN_VERSION} == 12 ]]; then
    #   execute_with_retries "apt-get install -y -q nvidia-kernel-open-dkms"
    # fi
    #
    # execute_with_retries "apt-get install -y -q --no-install-recommends cuda-drivers-${NVIDIA_DRIVER_VERSION_PREFIX}"
    # execute_with_retries "apt-get install -y -q --no-install-recommends cuda-toolkit-${CUDA_VERSION_MAJOR//./-}"



    curl -fsSL --retry-connrefused --retry 10 --retry-max-time 30 \
      "${NVIDIA_UBUNTU_REPO_KEY_PACKAGE}" -o /tmp/cuda-keyring.deb
    dpkg -i "/tmp/cuda-keyring.deb"

    curl -fsSL --retry-connrefused --retry 10 --retry-max-time 30 \
      "${NVIDIA_DEBIAN_GPU_DRIVER_URL}" -o driver.run
    bash "./driver.run" --silent --install-libglvnd

    curl -fsSL --retry-connrefused --retry 10 --retry-max-time 30 \
      "${NVIDIA_DEBIAN_CUDA_URL}" -o cuda.run
    bash "./cuda.run" --silent --toolkit --no-opengl-libs

    # enable a systemd service that updates kernel headers after reboot
    setup_systemd_update_headers

  elif [[ ${OS_NAME} == "ubuntu" ]]; then

    UBUNTU_VERSION=$(lsb_release -r|awk '{print $2}') # 20.04 or 22.04
    UBUNTU_VERSION=${UBUNTU_VERSION%.*} # 20 or 22

    execute_with_retries "apt-get install -y -q 'linux-headers-$(uname -r)'"

    readonly UBUNTU_REPO_CUDA_PIN="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${UBUNTU_VERSION}04/x86_64/cuda-ubuntu${UBUNTU_VERSION}04.pin"
    curl -fsSL --retry-connrefused --retry 3 --retry-max-time 5 \
      "${UBUNTU_REPO_CUDA_PIN}" -o /etc/apt/preferences.d/cuda-repository-pin-600

    readonly LOCAL_INSTALLER_DEB="cuda-repo-ubuntu${UBUNTU_VERSION}04-${CUDA_VERSION_MAJOR//./-}-local_${CUDA_VERSION}-${NVIDIA_DRIVER_VERSION}-1_amd64.deb"
    curl -fsSL --retry-connrefused --retry 3 --retry-max-time 5 \
      "https://developer.download.nvidia.com/compute/cuda/${CUDA_VERSION}/local_installers/${LOCAL_INSTALLER_DEB}" -o /tmp/local-installer.deb

    dpkg -i /tmp/local-installer.deb
    cp /var/cuda-repo-ubuntu${UBUNTU_VERSION}04-${CUDA_VERSION_MAJOR//./-}-local/cuda-*-keyring.gpg /usr/share/keyrings/
    execute_with_retries "apt-get update"

    execute_with_retries "apt-get install -y -q --no-install-recommends cuda-drivers-${NVIDIA_DRIVER_VERSION_PREFIX}"
    execute_with_retries "apt-get install -y -q --no-install-recommends cuda-toolkit-${CUDA_VERSION_MAJOR//./-}"

    # enable a systemd service that updates kernel headers after reboot
    setup_systemd_update_headers

  elif [[ ${OS_NAME} == "rocky" ]]; then

    ROCKY_VERSION=$(lsb_release -r | awk '{print $2}') # 8.8 or 9.1
    ROCKY_VERSION=${ROCKY_VERSION%.*} # 8 or 9

    readonly NVIDIA_ROCKY_REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/rhel${ROCKY_VERSION}/x86_64/cuda-rhel${ROCKY_VERSION}.repo"
    execute_with_retries "dnf config-manager --add-repo ${NVIDIA_ROCKY_REPO_URL}"
    execute_with_retries "dnf clean all"
    execute_with_retries "dnf -y -q module install nvidia-driver:${NVIDIA_DRIVER_VERSION_PREFIX}"
    execute_with_retries "dnf -y -q install cuda-toolkit-${CUDA_VERSION_MAJOR//./-}"
    modprobe nvidia

  else
    echo "Unsupported OS: '${OS_NAME}'"
    exit 1
  fi
  ldconfig
  echo "NVIDIA GPU driver provided by NVIDIA was installed successfully"
}

# Collects 'gpu_utilization' and 'gpu_memory_utilization' metrics
function install_gpu_agent() {
  download_agent
  install_agent_dependency
  start_agent_service
}

function download_agent(){
  if [[ ${OS_NAME} == rocky ]]; then
    execute_with_retries "dnf -y -q install git"
  else
    execute_with_retries "apt-get install git -y"
  fi
  mkdir -p /opt/google
  chmod 777 /opt/google
  cd /opt/google
  execute_with_retries "git clone https://github.com/GoogleCloudPlatform/compute-gpu-monitoring.git"
}

function install_agent_dependency(){
  execute_with_retries "apt-get install python3-venv -y"
  cd /opt/google/compute-gpu-monitoring/linux
  python3 -m venv venv
  venv/bin/pip install wheel
  venv/bin/pip install -Ur requirements.txt
}

function start_agent_service(){
  cp /opt/google/compute-gpu-monitoring/linux/systemd/google_gpu_monitoring_agent_venv.service /lib/systemd/system
  systemctl daemon-reload
  systemctl --no-reload --now enable /lib/systemd/system/google_gpu_monitoring_agent_venv.service
}

function set_hadoop_property() {
  local -r config_file=$1
  local -r property=$2
  local -r value=$3
  bdconfig set_property \
    --configuration_file "${HADOOP_CONF_DIR}/${config_file}" \
    --name "${property}" --value "${value}" \
    --clobber
}

function configure_yarn() {
  if [[ ! -f ${HADOOP_CONF_DIR}/resource-types.xml ]]; then
    printf '<?xml version="1.0" ?>\n<configuration/>' >"${HADOOP_CONF_DIR}/resource-types.xml"
  fi
  set_hadoop_property 'resource-types.xml' 'yarn.resource-types' 'yarn.io/gpu'

  set_hadoop_property 'capacity-scheduler.xml' \
    'yarn.scheduler.capacity.resource-calculator' \
    'org.apache.hadoop.yarn.util.resource.DominantResourceCalculator'

  set_hadoop_property 'yarn-site.xml' 'yarn.resource-types' 'yarn.io/gpu'
}

# This configuration should be applied only if GPU is attached to the node
function configure_yarn_nodemanager() {
  set_hadoop_property 'yarn-site.xml' 'yarn.nodemanager.resource-plugins' 'yarn.io/gpu'
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.resource-plugins.gpu.allowed-gpu-devices' 'auto'
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.resource-plugins.gpu.path-to-discovery-executables' $NVIDIA_SMI_PATH
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.linux-container-executor.cgroups.mount' 'true'
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.linux-container-executor.cgroups.mount-path' '/sys/fs/cgroup'
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.linux-container-executor.cgroups.hierarchy' 'yarn'
  set_hadoop_property 'yarn-site.xml' \
    'yarn.nodemanager.container-executor.class' \
    'org.apache.hadoop.yarn.server.nodemanager.LinuxContainerExecutor'
  set_hadoop_property 'yarn-site.xml' 'yarn.nodemanager.linux-container-executor.group' 'yarn'

}

function configure_gpu_exclusive_mode() {
  # check if running spark 3, if not, enable GPU exclusive mode
  local spark_version
  spark_version=$(spark-submit --version 2>&1 | sed -n 's/.*version[[:blank:]]\+\([0-9]\+\.[0-9]\).*/\1/p' | head -n1)
  if [[ ${spark_version} != 3.* ]]; then
    # include exclusive mode on GPU
    nvidia-smi -c EXCLUSIVE_PROCESS
  fi
}

function fetch_mig_scripts() {
  mkdir -p /usr/local/yarn-mig-scripts
  chmod 755 /usr/local/yarn-mig-scripts
  wget -P /usr/local/yarn-mig-scripts/ https://raw.githubusercontent.com/NVIDIA/spark-rapids-examples/branch-22.10/examples/MIG-Support/yarn-unpatched/scripts/nvidia-smi
  wget -P /usr/local/yarn-mig-scripts/ https://raw.githubusercontent.com/NVIDIA/spark-rapids-examples/branch-22.10/examples/MIG-Support/yarn-unpatched/scripts/mig2gpu.sh
  chmod 755 /usr/local/yarn-mig-scripts/*
}

function configure_gpu_script() {
  # Download GPU discovery script
  local -r spark_gpu_script_dir='/usr/lib/spark/scripts/gpu'
  mkdir -p ${spark_gpu_script_dir}
  # need to update the getGpusResources.sh script to look for MIG devices since if multiple GPUs nvidia-smi still
  # lists those because we only disable the specific GIs via CGROUPs. Here we just create it based off of:
  # https://raw.githubusercontent.com/apache/spark/master/examples/src/main/scripts/getGpusResources.sh
  echo '
#!/usr/bin/env bash

#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
NUM_MIG_DEVICES=$(nvidia-smi -L | grep MIG | wc -l)
ADDRS=$(nvidia-smi --query-gpu=index --format=csv,noheader | sed -e '\'':a'\'' -e '\''N'\'' -e'\''$!ba'\'' -e '\''s/\n/","/g'\'')
if [ $NUM_MIG_DEVICES -gt 0 ]; then
  MIG_INDEX=$(( $NUM_MIG_DEVICES - 1 ))
  ADDRS=$(seq -s '\''","'\'' 0 $MIG_INDEX)
fi
echo {\"name\": \"gpu\", \"addresses\":[\"$ADDRS\"]}
' > ${spark_gpu_script_dir}/getGpusResources.sh

  chmod a+rwx -R ${spark_gpu_script_dir}
}

function configure_gpu_isolation() {
  # enable GPU isolation
  sed -i "s/yarn\.nodemanager\.linux\-container\-executor\.group\=.*$/yarn\.nodemanager\.linux\-container\-executor\.group\=yarn/g" "${HADOOP_CONF_DIR}/container-executor.cfg"
  if [[ $IS_MIG_ENABLED -ne 0 ]]; then
    # configure the container-executor.cfg to have major caps
    printf '\n[gpu]\nmodule.enabled=true\ngpu.major-device-number=%s\n\n[cgroups]\nroot=/sys/fs/cgroup\nyarn-hierarchy=yarn\n' $MIG_MAJOR_CAPS >> "${HADOOP_CONF_DIR}/container-executor.cfg"
    printf 'export MIG_AS_GPU_ENABLED=1\n' >> "${HADOOP_CONF_DIR}/yarn-env.sh"
    printf 'export ENABLE_MIG_GPUS_FOR_CGROUPS=1\n' >> "${HADOOP_CONF_DIR}/yarn-env.sh"
  else
    printf '\n[gpu]\nmodule.enabled=true\n[cgroups]\nroot=/sys/fs/cgroup\nyarn-hierarchy=yarn\n' >> "${HADOOP_CONF_DIR}/container-executor.cfg"
  fi

  # Configure a systemd unit to ensure that permissions are set on restart
  cat >/etc/systemd/system/dataproc-cgroup-device-permissions.service<<EOF
[Unit]
Description=Set permissions to allow YARN to access device directories

[Service]
ExecStart=/bin/bash -c "chmod a+rwx -R /sys/fs/cgroup/cpu,cpuacct; chmod a+rwx -R /sys/fs/cgroup/devices"

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable dataproc-cgroup-device-permissions
  systemctl start dataproc-cgroup-device-permissions
}

function setup_gpu_yarn() {

  if [[ ${OS_NAME} == debian ]] || [[ ${OS_NAME} == ubuntu ]]; then
    export DEBIAN_FRONTEND=noninteractive
    execute_with_retries "apt-get update"
    execute_with_retries "apt-get install -y -q pciutils"
  elif [[ ${OS_NAME} == rocky ]] ; then
    execute_with_retries "dnf -y -q install pciutils"
  else
    echo "Unsupported OS: '${OS_NAME}'"
    exit 1
  fi

  # This configuration should be ran on all nodes
  # regardless if they have attached GPUs
  configure_yarn

  # Detect NVIDIA GPU
  if (lspci | grep -q NVIDIA); then
    # if this is called without the MIG script then the drivers are not installed
    if (/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader | uniq | wc -l); then
      NUM_MIG_GPUS=`/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader | uniq | wc -l`
      if [[ $NUM_MIG_GPUS -eq 1 ]]; then
        if (/usr/bin/nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader | grep Enabled); then
          IS_MIG_ENABLED=1
          NVIDIA_SMI_PATH='/usr/local/yarn-mig-scripts/'
          MIG_MAJOR_CAPS=`grep nvidia-caps /proc/devices | cut -d ' ' -f 1`
          fetch_mig_scripts
        fi
      fi
    fi

    if [[ ${OS_NAME} == debian ]] || [[ ${OS_NAME} == ubuntu ]]; then
      execute_with_retries "apt-get install -y -q 'linux-headers-$(uname -r)'"
    elif [[ ${OS_NAME} == rocky ]]; then
      echo "kernel devel and headers not required on rocky.  installing from binary"
    fi

    # if mig is enabled drivers would have already been installed
    if [[ $IS_MIG_ENABLED -eq 0 ]]; then
      install_nvidia_gpu_driver

      #Install GPU metrics collection in Stackdriver if needed
      if [[ ${INSTALL_GPU_AGENT} == true ]]; then
        install_gpu_agent
        echo 'GPU metrics agent successfully deployed.'
      else
        echo 'GPU metrics agent will not be installed.'
      fi
      configure_gpu_exclusive_mode
    fi

    configure_yarn_nodemanager
    configure_gpu_script
    configure_gpu_isolation
  elif [[ "${ROLE}" == "Master" ]]; then
    configure_yarn_nodemanager
    configure_gpu_script
  fi

  # Restart YARN services if they are running already
  for svc in resourcemanager nodemanager; do
    if [[ $(systemctl show hadoop-yarn-${svc}.service -p SubState --value) == 'running' ]]; then
      systemctl restart hadoop-yarn-${svc}.service
    fi
  done
}

function upgrade_kernel() {
  # Determine which kernel is installed
  if [[ "${OS_NAME}" == "debian" ]]; then
    CURRENT_KERNEL_VERSION=`cat /proc/version  | perl -ne 'print( / Debian (\S+) / )'`
  elif [[ "${OS_NAME}" == "ubuntu" ]]; then
    CURRENT_KERNEL_VERSION=`cat /proc/version | perl -ne 'print( /^Linux version (\S+) / )'`
  elif [[ ${OS_NAME} == rocky ]]; then
    KERN_VER=$(yum info --installed kernel | awk '/^Version/ {print $3}')
    KERN_REL=$(yum info --installed kernel | awk '/^Release/ {print $3}')
    # something like 4.18.0-425.10.1.el8_7
    CURRENT_KERNEL_VERSION="${KERN_VER}-${KERN_REL}"
  else
    echo "unsupported OS: ${OS_NAME}!"
    exit -1
  fi

  # Get latest version available in repos
  if [[ "${OS_NAME}" == "debian" ]]; then
    apt-get -qq update
    TARGET_VERSION=$(apt-cache show --no-all-versions linux-image-amd64 | awk '/^Version/ {print $2}')
  elif [[ "${OS_NAME}" == "ubuntu" ]]; then
    apt-get -qq update
    LATEST_VERSION=$(apt-cache show --no-all-versions linux-image-gcp | awk '/^Version/ {print $2}')
    TARGET_VERSION=`echo ${LATEST_VERSION} | perl -ne 'printf(q{%s-%s-gcp},/(\d+\.\d+\.\d+)\.(\d+)/)'`
  elif [[ "${OS_NAME}" == "rocky" ]]; then
    if yum info --available kernel ; then
      KERN_VER=$(yum info --available kernel | awk '/^Version/ {print $3}')
      KERN_REL=$(yum info --available kernel | awk '/^Release/ {print $3}')
      TARGET_VERSION="${KERN_VER}-${KERN_REL}"
    else
      TARGET_VERSION="${CURRENT_KERNEL_VERSION}"
    fi
  fi

  # Skip this script if we are already on the target version
  if [[ "${CURRENT_KERNEL_VERSION}" == "${TARGET_VERSION}" ]]; then
    echo "target kernel version [${TARGET_VERSION}] is installed"

    # Reboot may have interrupted dpkg.  Bring package system to a good state
    if [[ "${OS_NAME}" == "debian" || "${OS_NAME}" == "ubuntu" ]]; then
      dpkg --configure -a
    fi

    return 0
  fi

  # Install the latest kernel
  if [[ ${OS_NAME} == debian ]]; then
    apt-get install -y linux-image-amd64
  elif [[ "${OS_NAME}" == "ubuntu" ]]; then
    apt-get install -y linux-image-gcp
  elif [[ "${OS_NAME}" == "rocky" ]]; then
    dnf -y -q install kernel
  fi

  # Make it possible to reboot before init actions are complete - #1033
  DP_ROOT=/usr/local/share/google/dataproc
  STARTUP_SCRIPT="${DP_ROOT}/startup-script.sh"
  POST_HDFS_STARTUP_SCRIPT="${DP_ROOT}/post-hdfs-startup-script.sh"

  for startup_script in ${STARTUP_SCRIPT} ${POST_HDFS_STARTUP_SCRIPT} ; do
    sed -i -e 's:/usr/bin/env bash:/usr/bin/env bash\nexit 0:' ${startup_script}
  done

  cp /var/log/dataproc-initialization-script-0.log /var/log/dataproc-initialization-script-0.log.0

  systemctl reboot
}

# Verify if compatible linux distros and secure boot options are used
function check_os_and_secure_boot() {
  if [[ "${OS_NAME}" == "debian" ]]; then
    DEBIAN_VERSION=$(lsb_release -r | awk '{print $2}') # 10 or 11
    if [[ "${DEBIAN_VERSION}" != "10" && "${DEBIAN_VERSION}" != "11" && "${DEBIAN_VERSION}" != "12" ]]; then
      echo "Error: The Debian version (${DEBIAN_VERSION}) is not supported. Please use a compatible Debian version."
      exit 1
    fi
  elif [[ "${OS_NAME}" == "ubuntu" ]]; then
    UBUNTU_VERSION=$(lsb_release -r | awk '{print $2}') # 20.04
    UBUNTU_VERSION=${UBUNTU_VERSION%.*}
    if [[ "${UBUNTU_VERSION}" != "18" && "${UBUNTU_VERSION}" != "20" && "${UBUNTU_VERSION}" != "22" ]]; then
      echo "Error: The Ubuntu version (${UBUNTU_VERSION}) is not supported. Please use a compatible Ubuntu version."
      exit 1
    fi
  elif [[ "${OS_NAME}" == "rocky" ]]; then
    ROCKY_VERSION=$(lsb_release -r | awk '{print $2}') # 8 or 9
    ROCKY_VERSION=${ROCKY_VERSION%.*}
    if [[ "${ROCKY_VERSION}" != "8" && "${ROCKY_VERSION}" != "9" ]]; then
      echo "Error: The Rocky Linux version (${ROCKY_VERSION}) is not supported. Please use a compatible Rocky Linux version."
      exit 1
    fi
  fi

  if [[ "${SECURE_BOOT}" == "enabled" ]]; then
    echo "Error: Secure Boot is enabled. Please disable Secure Boot while creating the cluster."
    exit 1
  fi
}


function update_backports_url() {
    DEBIAN_VERSION=$(lsb_release -r|awk '{print $2}') # 10 or 11

    if [[ ${DEBIAN_VERSION} == 10 ]]; then
      sed -i 's#deb.debian.org/debian buster-backports#archive.debian.org/debian buster-backports#g' /etc/apt/sources.list
    fi
}

function install_rapidai() {
  readonly miniforge_version="23.1.0-1"
  readonly miniforge_sha256="cba9a744454039944480871ed30d89e4e51a944a579b461dd9af60ea96560886"

  apt install -y libarchive13


  rm -rf /opt/conda/mamba

  wget -nv https://github.com/conda-forge/miniforge/releases/download/${miniforge_version}/Mambaforge-${miniforge_version}-Linux-x86_64.sh -O miniforge.sh
  echo "${miniforge_sha256} miniforge.sh" > miniforge.sha256
  export HOME=/root
  bash miniforge.sh -b -p /opt/conda/mamba
  /opt/conda/mamba/bin/conda update --yes -n base -c defaults conda
  /opt/conda/mamba/bin/conda config --set always_yes yes --set changeps1 no
  /opt/conda/mamba/bin/conda info -a
  /opt/conda/mamba/bin/conda install mamba -c conda-forge

  # /opt/conda/default/bin/conda config --add channels conda-forge
  # /opt/conda/default/bin/conda update -n base --all
  # /opt/conda/default/bin/conda install -n base mamba
  # /opt/conda/dfeault/bin/conda install -n base conda-libmamba-solver
  # /opt/conda/miniconda3/bin/mamba install -c rapidsai -c conda-forge -c nvidia  rapids=24.04 cuda-version=11.8 -y
}


function main() {
  update_backports_url
  check_os_and_secure_boot
  if [[ "${OS_NAME}" == "rocky" ]]; then
    if dnf list kernel-devel-$(uname -r) && dnf list kernel-headers-$(uname -r); then
      echo "kernel devel and headers packages are available.  Proceed without kernel upgrade."
    else
      upgrade_kernel
    fi
  fi
  setup_gpu_yarn
  if [[ "${RUNTIME}" == "SPARK" ]]; then
    install_spark_rapids
    configure_spark
    echo "RAPIDS initialized with Spark runtime"
  else
    echo "Unsupported RAPIDS Runtime: ${RUNTIME}"
    exit 1
  fi

  install_rapidai

  for svc in resourcemanager nodemanager; do
    if [[ $(systemctl show hadoop-yarn-${svc}.service -p SubState --value) == 'running' ]]; then
      systemctl restart hadoop-yarn-${svc}.service
    fi
  done
}

main
