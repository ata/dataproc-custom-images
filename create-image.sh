#!/bin/bash

python3 generate_custom_image.py \
    --image-name debian11-rapid-1 \
    --dataproc-version 2.1.44-debian11 \
    --customization-script ./spark-rapids.sh  \
    --no-smoke-test \
    --zone asia-southeast1-b \
    --machine-type n1-highmem-8 \
    --accelerator type=nvidia-tesla-t4,count=1 \
    --disk-size 100 \
    --gcs-bucket vidio-bigdata-prod-logs \
    --network projects/kmk-prod/global/networks/kmk-prod \
    --subnetwork projects/kmk-prod/regions/asia-southeast1/subnetworks/kmk-prod-application \
    --metadata install-gpu-agent=true,rapids-runtime=SPARK,driver-version=520.61.05,cuda-version=11.8.0 \
    --no-external-ip
