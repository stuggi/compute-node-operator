#!/bin/bash
#
# Copyright 2020 Red Hat Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

set -ex

OS_COMPUTE_API_VERSION="2.latest"
OS_PLACEMENT_API_VERSION="1.latest"

if [ -z "${SCALE_DOWN_NODE_NAME}" ] ; then
  echo "No host to scale down provides!"
  exit 1
fi

# Get compute ID from service list
COMPUTE_SERVICE_ID=$(openstack compute service list -f value -c ID \
                      --host ${SCALE_DOWN_NODE_NAME})

# Delete nova-compute from registered nova services
while [ -n "${COMPUTE_SERVICE_ID}" ]; do
  openstack compute service delete ${COMPUTE_SERVICE_ID}
  sleep 5
  COMPUTE_SERVICE_ID=$(openstack compute service list -f value -c ID \
                        --host ${SCALE_DOWN_NODE_NAME})
done

# TODO: mschuppert - delete neutron OVN controller when supported

# Delete nova-compute as a placement resource provider
PLACEMENT_PROVIDER_ID=$(openstack resource provider list -f value \
                          -c uuid --name ${SCALE_DOWN_NODE_NAME})

while [ -n "${PLACEMENT_PROVIDER_ID}" ]; do
  # Check if resource provider still has allocations
  # If the resource provider has orphaned allocations, delete of resource
  # provider will fail:
  # openstack resource provider delete 5361d775-7f4a-4f5d-aacc-03f8eeea881b
  # Unable to delete resource provider 5361d775-7f4a-4f5d-aacc-03f8eeea881b: Resource provider has allocations. (HTTP 409)

  PLACEMENT_PROVIDER_ALLOCATIONS=( $(openstack resource provider show -f json \
                                    --allocations ${PLACEMENT_PROVIDER_ID} | \
                                    jq -c '.allocations | keys| .[]') )

  # Delete allocations from placement for the compute if there are any
  #
  # Loop through the allocations and remove them for the provider we remove. We
  # do not use openstack resource provider# allocation delete here because that
  # will remove the allocations for the server from all resource providers,
  # including the compute where the instance is now running.
  for CONSUMER_ID in "${#PLACEMENT_PROVIDER_ALLOCATIONS[@]}"; do
    echo "${SCALE_DOWN_NODE_NAME} has allocations: ${ALLOCATIONS}"
    echo "Remove allocation for consumer: ${CONSUMER_ID} on \
      provider ${SCALE_DOWN_NODE_NAME}"

    # Note: when we have osc-placement 1.8.0 or newer, this can be
    #       changed to the openstack resource provider allocation unset
    #       command to remove the allocations for a consumer from the
    #       resource provider we remove.
    openstack resource provider allocation unset \
      --provider ${PLACEMENT_PROVIDER_ID} ${CONSUMER_ID}
  fi

  # Delete resource provider
  openstack resource provider delete ${PLACEMENT_PROVIDER_ID} || true

  sleep 5
  PLACEMENT_PROVIDER_ID=$(openstack resource provider list -f value \
                            -c uuid --name ${SCALE_DOWN_NODE_NAME})
done

exit 0
