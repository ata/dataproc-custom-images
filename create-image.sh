#!/bin/bash

python3 generate_custom_image.py \
    --image-name rapids-debian10-5 \
    --dataproc-version 2.0.96-debian10 \
    --customization-script ./spark-rapids.sh  \
    --no-smoke-test \
    --zone asia-southeast1-b \
    --machine-type n1-highmem-8 \
    --accelerator type=nvidia-tesla-t4,count=1 \
    --disk-size 100 \
    --gcs-bucket vidio-bigdata-prod-logs \
    --network projects/kmk-prod/global/networks/kmk-prod \
    --subnetwork projects/kmk-prod/regions/asia-southeast1/subnetworks/kmk-prod-application \
    --metadata install-gpu-agent=true,rapids-runtime=SPARK,cuda-version=11.8.0,spark-rapids-version=23.12.2 \
    --no-external-ip
