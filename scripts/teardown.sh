#!/bin/bash
#set -e

working_dir=$(dirname "$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )")
namespace="$1"
monitor_ns="ltmonitoring"

[ -n "$namespace" ] || read -p 'Enter namespace to clean up. Only load testing resources will be deleted: ' namespace

kubectl delete -n $namespace -f $working_dir/master/jmeter_master_configmap.yaml
kubectl delete -n $namespace -f $working_dir/master/jmeter_master_deploy.yaml

kubectl delete -n $namespace -f $working_dir/slaves/jmeter_slaves_deploy.yaml
kubectl delete -n $namespace -f $working_dir/slaves/jmeter_slaves_svc.yaml

kubectl delete -n $monitor_ns -f $working_dir/influxdb/jmeter_influxdb_configmap.yaml
kubectl delete -n $monitor_ns -f $working_dir/influxdb/jmeter_influxdb_deploy.yaml
kubectl delete -n $monitor_ns -f $working_dir/influxdb/jmeter_influxdb_svc.yaml

kubectl delete -n $monitor_ns -f $working_dir/grafana/jmeter_grafana_deploy.yaml
kubectl delete -n $monitor_ns -f $working_dir/grafana/jmeter_grafana_svc.yaml

kubectl delete -n $monitor_ns -f $working_dir/prometheus/prometheus-service-account.yaml
kubectl delete -n $monitor_ns -f $working_dir/prometheus/prometheus-configmap.yaml
kubectl delete -n $monitor_ns -f $working_dir/prometheus/prometheus-deployment.yaml
kubectl delete -n $monitor_ns -f $working_dir/prometheus/prometheus-svc.yaml

helm uninstall kube-state-metrics prometheus-community/kube-state-metrics -n kube-system
