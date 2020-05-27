# compute-node-operator
Compute-Node Operator


## Pre Req:
- OCP 4 installed

#### Clone it

    git clone https://github.com/openstack-k8s-operators/compute-node-operator.git
    cd compute-node-operator

#### Create the operator

This is optional, a prebuild operator from quay.io/ltomasbo/compute-operator could be used, e.g. quay.io/ltomasbo/compute-node-operator:v0.0.1 .

Build the image, using your custom registry you have write access to

    operator-sdk build <image e.g quay.io/ltomasbo/compute-node-operator:v0.0.X>

Replace `image:` in deploy/operator.yaml with your custom registry

    sed -i 's|REPLACE_IMAGE|quay.io/ltomasbo/compute-node-operator:v0.0.X|g' deploy/operator.yaml
    podman push --authfile ~/ltomasbo-auth.json quay.io/ltomasbo/compute-node-operator:v0.0.X

#### Install the operator

Create CRDs
    
    oc create -f deploy/crds/compute-node.openstack.org_computenodeopenstacks_crd.yaml

Create role, role_binding and service_account

    oc create -f deploy/role.yaml
    oc create -f deploy/role_binding.yaml
    oc create -f deploy/service_account.yaml

Install the operator

    oc create -f deploy/operator.yaml

If necessary check logs with

    POD=`oc get pods -l name=compute-node-operator --field-selector=status.phase=Running -o name | head -1 -`; echo $POD
    oc logs $POD -f

Create the ConfigMap and Secret required for the OpenStack client to be able to connect to the OpenStack API.
This is required for the pre/post scripts during scale down operation. In the end this should be created by a
control-plane operator.

Create `openstackclient` ConfigMap file (e.g. `openstackclient-cm.yaml`)

    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: openstackclient
      namespace: openstack
    data:
      NOVA_VERSION: "1.1"
      COMPUTE_API_VERSION: "1.1"
      OS_USER_DOMAIN_NAME: "Default"
      OS_PROJECT_DOMAIN_NAME: "Default"
      OS_NO_CACHE: "True"
      OS_CLOUDNAME: "overcloud"
      PYTHONWARNINGS: "ignore:Certificate has no, ignore:A true SSLContext object is not available"
      OS_AUTH_TYPE: "password"
      OS_AUTH_URL: "http://192.168.25.100:5000"
      OS_IDENTITY_API_VERSION: "3"
      OS_COMPUTE_API_VERSION: "2.latest"
      OS_IMAGE_API_VERSION: "2"
      OS_VOLUME_API_VERSION: "3"
      OS_REGION_NAME: "regionOne"

Create `openstackclient-admin` Secret which for a user with admin privileges (e.g. `openstackclient-admin-secret.yaml`)

    apiVersion: v1
    kind: Secret
    metadata:
      name: openstackclient-admin
      namespace: openstack
    data:
      OS_USERNAME: YWRtaW4=
      OS_PROJECT_NAME: YWRtaW4=
      OS_PASSWORD: YWRtaW4tcGFzc3dvcmQ=

Create both, ConfigMap and Secret using:

    oc apply -f openstackclient-cm.yaml -f openstackclient-admin-secret.yaml

Create custom resource for a compute node which specifies the needed information (e.g.: `deploy/crds/compute-node.openstack.org_v1alpha1_computenodeopenstack_cr.yaml`):

    apiVersion: compute-node.openstack.org/v1alpha1
    kind: ComputeNodeOpenStack
    metadata:
      name: example-computenodeopenstack
      namespace: openshift-machine-api
    spec:
      # Add fields here
      roleName: worker-osp
      clusterName: ostest
      baseWorkerMachineSetName: ostest-worker-0
      k8sServiceIp: 172.30.0.1
      apiIntIp: 192.168.111.5
      workers: 1
      corePinning: "4-7"   # Optional
      infraDaemonSets:     # Optional
      - name: multus
        namespace: openshift-multus
      - name: node-exporter
        namespace: openshift-monitoring
      - name: machine-config-daemon
        namespace: openshift-machine-config-operator
      drain:
        # image which provides the openstackclient and has the osc-placement plugin installed
        drainPodImage: quay.io/openstack-k8s-operators/tripleo-deploy
        # enable automatic live migration of instances in ACTIVE state
        # all other instances in different state need to be cleaned up manually
        enabled: true/false # Optional, default is false

Apply the CR:

    oc apply -f deploy/crds/compute-node.openstack.org_v1alpha1_computenodeopenstack_cr.yaml
    
    oc get pods -n openshift-machine-api
    NAME                                   READY   STATUS    RESTARTS   AGE
    compute-node-operator-ffd64796-vshg6   1/1     Running   0          119s

Get the generated machineconfig and machinesets

    oc get machineset  -n openshift-machine-api
    oc get machineconfigpool
    oc get machineconfig


## POST steps

### Add compute workers

Edit the computenodeopenstack CR:

    oc -n openshift-machine-api edit computenodeopenstacks.compute-node.openstack.org example-computenodeopenstack
    # Modify the number of workers and exit

    oc get machineset -n openshift-machine-api
    # check the desired amount has been updated

### Remove compute workers

There are different ways to remove a compute worker node from the OpenStack environment:

#### Remove a random compute worker node

Edit the computenodeopenstack CR and lower the workers number, save and exit:

    oc -n openshift-machine-api edit computenodeopenstacks.compute-node.openstack.org example-computenodeopenstack

OCP will choose a compute worker node to be removed. Per the `deletePolicy` of the compute worker machineset is set to `Newest`, therefore the newest compute node is expected to be removed. Depending on the status of the instances and `drain` configuration, manual migration/cleanup of the instances is required.

The following command will show which compute worker node got disabled to be removed.

    oc get nodes

#### Remove a specific compute worker node

Edit the computenodeopenstack CR, lower the workers number and add a `nodesToDelete` section in the spec with the details of the worker node which should be removed:

    oc -n openshift-machine-api edit computenodeopenstacks.compute-node.openstack.org example-computenodeopenstack

Modify the number of `workers` and add the `nodesToDelete` section to the spec:

    nodesToDelete:
    - name: <name of the compute worker node, e.g. worker-3>
      # enable disable live migration for this node. If not specified the global setting from the
      # `drain:` section is used. If not specified there, the default is `false`
      drain: true/false

Save and exit.

## Cleanup

First delete all instances running on the OCP:

    oc delete -f deploy/crds/compute-node.openstack.org_v1alpha1_computenodeopenstack_cr.yaml
    oc delete -f deploy/operator.yaml
    oc delete -f deploy/role.yaml
    oc delete -f deploy/role_binding.yaml
    oc delete -f deploy/service_account.yaml
    oc delete -f deploy/crds/compute-node.openstack.org_computenodeopenstacks_crd.yaml
