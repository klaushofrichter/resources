#!/bin/bash
set -e

#
# read common settings
source ./config.sh

echo
echo "==== $0: Feature Flags Information:"
echo "SLACK_ENABLE: ${SLACK_ENABLE} - controls if Slack is used for alerting. Slack account is required."
echo "GRAFANA_CLOUD_ENABLE: ${GRAFANA_CLOUD_ENABLE} - controls if grafana-cloud is deployed. Grafana Cloud account is required."
echo "GOLDILOCKS_ENABLE: ${GOLDILOCKS_ENABLE} - controls if goldilocks is deployed."
echo "RESOURCEPATCH: ${RESOURCEPATCH} - controls if resource settings are patched everywhere."
echo "configuration is defined in ./config.sh"

#
# remove cluster if it exists
if [[ ! -z $(k3d cluster list | grep "^${CLUSTER}") ]]; then
  echo
  echo "==== $0: remove existing cluster"
  read -p "K3D cluster \"${CLUSTER}\" exists. Ok to delete it and restart? (y/n) " -n 1 -r
  echo
  if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
    echo "bailing out..."
    exit 1
  fi
  k3d cluster delete ${CLUSTER}
fi  

echo
echo "==== $0: Create new cluster ${CLUSTER} for app ${APP}:${VERSION}"
if [ ${SLACK_ENABLE} == "yes" ]; then
  echo -n "sending Slack message to announce the setup..."
  ./slack.sh "Cluster ${CLUSTER} setup in progress...."
fi
cat k3d-config.yaml.template | envsubst "${ENVSUBSTVAR}" > /tmp/k3d-config.yaml
k3d cluster create --config /tmp/k3d-config.yaml
rm /tmp/k3d-config.yaml
export KUBECONFIG=$(k3d kubeconfig write ${CLUSTER})
echo "export KUBECONFIG=${KUBECONFIG}"

#
# Patch resources when requested for metrics server and local path provider 
if [ "${RESOURCEPATCH}" == "yes" ]; then

  echo
  echo "==== $0: Patching coredns resource settings into the Deployment"
  kubectl rollout status deployment.apps coredns -n kube-system --request-timeout 5m
  kubectl patch deployment coredns -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"coredns","resources":{"limits":{"cpu":"300m","memory":"200M"},"requests":{"cpu":"100m","memory":"70M"}}}]}}}}'

  echo
  echo "==== $0: Patching metrics server resource settings into the Deployment"
  kubectl rollout status deployment.apps metrics-server -n kube-system --request-timeout 5m
  kubectl patch deployment metrics-server -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"metrics-server","resources":{"limits":{"cpu":"250m","memory":"300M"},"requests":{"cpu":"15m","memory":"100M"}}}]}}}}'
  
  echo
  echo "==== $0: Patching local-path-provisioner resource settings into the Deployment"
  kubectl rollout status deployment.apps local-path-provisioner -n kube-system --request-timeout 5m
  kubectl patch deployment local-path-provisioner -n kube-system -p '{"spec":{"template":{"spec":{"containers":[{"name":"local-path-provisioner","resources":{"limits":{"cpu":"50m","memory":"160M"},"requests":{"cpu":"10m","memory":"80M"}}}]}}}}'

  echo
  echo "==== $0: Wait for metrics server and local path provisioner to be ready."
  kubectl rollout status deployment.apps coredns -n kube-system --request-timeout 5m  
  kubectl rollout status deployment.apps local-path-provisioner -n kube-system --request-timeout 5m  
  kubectl rollout status deployment.apps metrics-server -n kube-system --request-timeout 5m

fi

echo
echo "==== $0: Loading helm repositories"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add fluent https://fluent.github.io/helm-charts
helm repo add influxdata https://helm.influxdata.com/
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add fairwinds-stable https://charts.fairwinds.com/stable
helm repo update

echo
echo "==== $0: Installing Prometheus CRDs version ${PROMOPERATOR} before installing Prometheus itself"
echo "Note that the Promoperator CRDs must fit to the Kube-Prometheus-Stack helm chart, currently version ${KUBEPROMETHEUSSTACKCHART}."
echo "If you change the versions in ./config.sh, make sure that there is compatibility by looking at the helm chart release notes."
BASE="https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v${PROMOPERATOR}/example/prometheus-operator-crd"
CRDS="alertmanagerconfigs alertmanagers podmonitors probes prometheuses prometheusrules servicemonitors thanosrulers"
for crd in ${CRDS} 
do
  kubectl create -f ${BASE}/monitoring.coreos.com_${crd}.yaml
done

#
# deploy ingress-nginx
./ingress-nginx-deploy.sh

#
# undeploy and deploy influxdb
./influxdb-deploy.sh

#
# undeploy and deploy fluentbit
./fluentbit-deploy.sh

#
# build and deploy the application
./app-deploy.sh

#
# deploy prometheus/alertmanager/grafana
./prom-deploy.sh

#
# deploy grafana cloud agent
[ ${GRAFANA_CLOUD_ENABLE} == "yes" ] && ./grafana-cloud-deploy.sh

#
# deploy golidlock
[ ${GOLDILOCKS_ENABLE} == "yes" ] && ./goldilocks-deploy.sh

#
# generate a little random traffic
./app-traffic.sh 4 1 1  # four calls with delay between 1 and 2 seconds between calls

echo 
echo "==== $0: Various information"
if [ ${SLACK_ENABLE} == "yes" ]; then 
  echo -n "Sending Slack message to announce deployment. "
  ./slack.sh "Cluster ${CLUSTER} running."
fi
echo "export KUBECONFIG=${KUBECONFIG}"
echo "Lens metrics setting: monitoring/prom-kube-prometheus-stack-prometheus:9090/prom"
echo "${APP} info API: http://localhost:${HTTPPORT}/service/info"
echo "${APP} random API: http://localhost:${HTTPPORT}/service/random"
echo "${APP} metrics API: http://localhost:${HTTPPORT}/service/metrics"
echo "influxdb ui: http://localhost:${INFLUXUIPORT} (configure influx server at http://localhost:${INFLUXPORT})"
[ "${GOLDILOCKS_ENABLE}" == "yes" ] && echo "goldilocks: http://localhost:${GOLDILOCKSPORT}"
echo "prometheus: http://localhost:${HTTPPORT}/prom/targets"
echo "grafana: http://localhost:${HTTPPORT}  (use admin/${GRAFANA_LOCAL_ADMIN_PASS} to login)"
echo "alertmanager: http://localhost:${HTTPPORT}/alert"
if [ "${GRAFANA_CLOUD_ENABLE}" == "yes" ]; then
  echo "grafanacloud portal: https://grafana.com/orgs/${GRAFANA_CLOUD_ORG}"
  echo "grafana cloud instance: https://${GRAFANA_CLOUD_ORG}.grafana.net"
fi
[ -x ${AMTOOL} ] && sleep 4 && echo -n "Alertmanager " && ${AMTOOL} config routes
