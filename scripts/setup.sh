#!/bin/bash
set -e
gcloud auth configure-docker -q --verbosity="error" > /dev/null

GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
NC=$(tput sgr0)

working_dir=$(dirname "$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )")
project=$(gcloud config get-value project)
monitor_ns="ltmonitoring"
namespace="$1"
zone="$2"

function build_base_image() {
	existing_tags=$(gcloud container images list-tags --format=json gcr.io/$project/jmeter-base)
	if [[ "$existing_tags" == "[]" ]]; then
		printf "%-50s %s" "Building jmeter base image..."
		docker build --tag="gcr.io/$project/jmeter-base:latest" $working_dir -f $working_dir/Dockerfile-base > /dev/null 2>&1
		docker push gcr.io/$project/jmeter-base > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			printf "${GREEN}[OK]${NC}\n"
		fi
	fi
}

function build_master_image() {
	sed -i -e "s/\[project\]/$project/g" $working_dir/master/jmeter_master_deploy.yaml
	sed -i -e "s/\[project\]/$project/g" $working_dir/master/Dockerfile-master
	existing_tags=$(gcloud container images list-tags --format=json gcr.io/$project/jmeter-master)
	if [[ "$existing_tags" == "[]" ]]; then
		printf "%-50s %s" "Building jmeter master image..."
		docker build --tag="gcr.io/$project/jmeter-master:latest" $working_dir -f $working_dir/master/Dockerfile-master > /dev/null 2>&1
		docker push gcr.io/$project/jmeter-master > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			printf "${GREEN}[OK]${NC}\n"
		fi
	fi
}

function build_worker_image() {
	sed -i -e "s/\[project\]/$project/g" $working_dir/slaves/jmeter_slaves_deploy.yaml
	sed -i -e "s/\[project\]/$project/g" $working_dir/slaves/Dockerfile-slave
	existing_tags=$(gcloud container images list-tags --format=json gcr.io/$project/jmeter-slave)
	if [[ "$existing_tags" == "[]" ]]; then
		printf "%-50s %s" "Building jmeter worker image..."
		docker build --tag="gcr.io/$project/jmeter-slave:latest" $working_dir -f $working_dir/slaves/Dockerfile-slave > /dev/null 2>&1
		docker push gcr.io/$project/jmeter-slave > /dev/null 2>&1
		if [ $? -eq 0 ]; then
			printf "${GREEN}[OK]${NC}\n"
		fi
	fi
}

function create_cluster(){
	read -p "Do you wish to create new cluster? " yn
    	case $yn in
        	[Yy]* ) 
			printf "%-50s %s" "Creating Jmeter GKE cluster..."
			cluster="jmeter-cluster-$(echo $RANDOM | md5sum | head -c 5)"
        		gcloud beta container --project $project clusters create $cluster \
                		--zone $zone \
                		--machine-type "e2-custom-8-8192" \
                		--image-type "COS_CONTAINERD" \
                		--disk-type "pd-balanced" \
                		--disk-size "25" \
                		--num-nodes "2" \
                		--enable-ip-alias \ > /dev/null 2>&1
        		if [ $? -eq 0 ]; then
                		printf "${GREEN}[OK]${NC}\n"
        		fi 
			;;
        	[Nn]* ) 
			read -p "Enter name of an existing cluster " cluster
			read -p "Enter zone " zone
			gcloud container clusters get-credentials $cluster --zone $zone --project $project 
			;;
        	* ) 
			echo "Please answer yes or no.";;
    	esac
}

function create_resources() {
	[ -n "$namespace" ] || read -p 'Create a new namespace for jmeter setup ' namespace
	kubectl create namespace $namespace > /dev/null 2>&1
	if [ $? -eq 0 ]; then
		printf "%-50s %s" "Creating namespace..."
		printf "${GREEN}[OK]${NC}\n"
	fi
	
	printf "%-50s %s" "Creating Jmeter workers..."
	kubectl apply -n $namespace -f $working_dir/slaves/jmeter_slaves_deploy.yaml > /dev/null 2>&1
	kubectl apply -n $namespace -f $working_dir/slaves/jmeter_slaves_svc.yaml > /dev/null 2>&1
	if [ $? -eq 0 ]; then
		printf "${GREEN}[OK]${NC}\n"
	fi

	printf "%-50s %s" "Creating Jmeter master..."
	kubectl apply -n $namespace -f $working_dir/master/jmeter_master_configmap.yaml > /dev/null 2>&1
	kubectl apply -n $namespace -f $working_dir/master/jmeter_master_deploy.yaml > /dev/null 2>&1
	if [ $? -eq 0 ]; then
                printf "${GREEN}[OK]${NC}\n"
        fi

	kubectl get ns $monitor_ns > /dev/null 2>&1 ||
		kubectl create ns $monitor_ns > /dev/null 2>&1

	printf "%-50s %s" "Configuring Influxdb..."
	kubectl apply -n $monitor_ns -f $working_dir/influxdb/jmeter_influxdb_configmap.yaml > /dev/null 2>&1
	kubectl apply -n $monitor_ns -f $working_dir/influxdb/jmeter_influxdb_deploy.yaml > /dev/null 2>&1
	kubectl apply -n $monitor_ns -f $working_dir/influxdb/jmeter_influxdb_svc.yaml > /dev/null 2>&1
	if [ $? -eq 0 ]; then
                printf "${GREEN}[OK]${NC}\n"
        fi

	printf "%-50s %s" "Configuring Grafana..."
	kubectl apply -n $monitor_ns -f $working_dir/grafana/jmeter_grafana_deploy.yaml > /dev/null 2>&1
	kubectl apply -n $monitor_ns -f $working_dir/grafana/jmeter_grafana_svc.yaml > /dev/null 2>&1
	if [ $? -eq 0 ]; then
                printf "${GREEN}[OK]${NC}\n"
        fi

	printf "%-50s %s" "Configuring Prometheus..."
	kubectl apply -n $monitor_ns -f $working_dir/prometheus/prometheus-service-account.yaml > /dev/null 2>&1
	kubectl apply -n $monitor_ns -f $working_dir/prometheus/prometheus-configmap.yaml > /dev/null 2>&1
	kubectl apply -n $monitor_ns -f $working_dir/prometheus/prometheus-deployment.yaml > /dev/null 2>&1
	kubectl apply -n $monitor_ns -f $working_dir/prometheus/prometheus-svc.yaml > /dev/null 2>&1
	if [ $? -eq 0 ]; then
                printf "${GREEN}[OK]${NC}\n"
        fi

	kubectl get deploy -n kube-system | grep kube-state-metrics > /dev/null 2>&1 ||
		(printf "%-50s %s" "Enabling kube-state-metrics..."
		helm repo add prometheus-community https://prometheus-community.github.io/helm-charts > /dev/null 2>&1
		helm repo update > /dev/null 2>&1
		helm install kube-state-metrics prometheus-community/kube-state-metrics -n kube-system  > /dev/null 2>&1
		if [ $? -eq 0 ]; then
                	printf "${GREEN}[OK]${NC}\n"
		fi)

	printf "%-50s %s" "Waiting for pods to be ready..."
	while [[ $(kubectl get pods -n $namespace \
		-l jmeter_mode=master \
		-o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; 
	do
   		sleep 1
	done
	
	while [[ $(kubectl get pods -n $namespace \
		-l jmeter_mode=slave \
		-o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | awk -F " " '{print $1}' | xargs) != "True" ]]; 
	do
                sleep 1
        done
	
	while [[ $(kubectl get pods -n $monitor_ns \
		-l app=influxdb-jmeter \
		-o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; 
	do
                sleep 1
        done

	while [[ $(kubectl get pods -n $monitor_ns \
		-l app=jmeter-grafana \
		-o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; 
	do
                sleep 1
        done
	
	while [[ $(kubectl get pods -n $monitor_ns \
		-l app=prometheus-server \
		-o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; 
	do
                sleep 1
        done
	if [ $? -eq 0 ]; then
                printf "${GREEN}[OK]${NC}\n"
        fi
}

function create_dashboards() {
	printf "%-50s %s" "Creating Influxdb jmeter database..."
	influxdb_pod=`kubectl get po -n $monitor_ns | grep influxdb-jmeter | awk '{print $1}'`
	kubectl exec -ti -n $monitor_ns $influxdb_pod -- influx -execute 'CREATE DATABASE jmeter' > /dev/null 2>&1
	if [ $? -eq 0 ]; then
                printf "${GREEN}[OK]${NC}\n"
        fi

	master_pod=`kubectl get po -n $namespace | grep jmeter-master | awk '{print $1}'`
	kubectl exec -ti -n $namespace $master_pod -- cp -r /load_test /jmeter/load_test > /dev/null 2>&1
	kubectl exec -ti -n $namespace $master_pod -- chmod 755 /jmeter/load_test > /dev/null 2>&1

	printf "%-50s %s" "Adding Influxdb as a data source in Grafana..."
	grafana_pod=`kubectl get po -n $monitor_ns | grep jmeter-grafana | awk '{print $1}'`
	response=$(kubectl exec -ti -n $monitor_ns $grafana_pod -- \
		curl 'http://admin:admin@127.0.0.1:3000/api/datasources' -X POST \
		-H 'Content-Type: application/json;charset=UTF-8' \
		--data-binary '{"name":"jmeterdb","type":"influxdb","url":"http://jmeter-influxdb:8086","access":"proxy","isDefault":true,"database":"jmeter","user":"admin","password":"admin"}' \
		--write-out %{http_code} --silent --output /tmp/log)
	if [[ $response -ne 200 ]]; then
                printf "${RED}[NOK]${NC}\n"
                kubectl exec -ti -n $monitor_ns $grafana_pod -- cat /tmp/log
		echo
        else
                printf "${GREEN}[OK]${NC}\n"
        fi

	printf "%-50s %s" "Adding Prometheus as a data source in Grafana..."
	response=$(kubectl exec -ti -n $monitor_ns $grafana_pod -- \
		curl 'http://admin:admin@127.0.0.1:3000/api/datasources' -X POST \
		-H 'Content-Type: application/json;charset=UTF-8' \
		--data-binary '{"name": "promdb", "type": "prometheus","url": "http://jmeter-promdb:9090", "access":"proxy","basicAuth":false}' \
		--write-out %{http_code} --silent --output /tmp/log)
	if [[ $response -ne 200 ]]; then
                printf "${RED}[NOK]${NC}\n"
                kubectl exec -ti -n $monitor_ns $grafana_pod -- cat /tmp/log
		echo
        else
                printf "${GREEN}[OK]${NC}\n"
        fi

	printf "%-50s %s" "Importing Jmeter results monitoring dashboard..."
	kubectl cp $working_dir/grafana/jmeter-results-monitor.json -n $monitor_ns $grafana_pod:/tmp/jmeter-results-monitor.json
	response=$(kubectl exec -ti -n $monitor_ns $grafana_pod -- \
		curl -X POST 'http://admin:admin@127.0.0.1:3000/api/dashboards/db' \
		-H 'Content-Type: application/json' \
		--data @/tmp/jmeter-results-monitor.json \
		--write-out %{http_code} --silent --output /tmp/log)
	if [[ $response -ne 200 ]]; then
                printf "${RED}[NOK]${NC}\n"
                kubectl exec -ti -n $monitor_ns $grafana_pod -- cat /tmp/log
		echo
        else
                printf "${GREEN}[OK]${NC}\n"
        fi

	printf "%-50s %s" "Importing Jmeter workers monitoring dashboard..."
	kubectl cp $working_dir/grafana/jmeter-workers-monitor.json -n $monitor_ns $grafana_pod:/tmp/jmeter-workers-monitor.json
	response=$(kubectl exec -ti -n $monitor_ns $grafana_pod \
                -- curl -X POST 'http://admin:admin@127.0.0.1:3000/api/dashboards/db' \
                -H 'Content-Type: application/json' \
                --data @/tmp/jmeter-workers-monitor.json \
		--write-out %{http_code} --silent --output /tmp/log)
	if [[ $response -ne 200 ]]; then
                printf "${RED}[NOK]${NC}\n"
		kubectl exec -ti -n $monitor_ns $grafana_pod -- cat /tmp/log
		echo
	else
		printf "${GREEN}[OK]${NC}\n"
        fi

	printf "%-50s %s" "Importing Kubernetes pod monitoring dashboard..."
	kubectl cp $working_dir/grafana/pod-monitor.json -n $monitor_ns $grafana_pod:/tmp/pod-monitor.json
	response=$(kubectl exec -ti -n $monitor_ns $grafana_pod \
		-- curl -X POST 'http://admin:admin@127.0.0.1:3000/api/dashboards/db' \
		-H 'Content-Type: application/json' \
		--data @/tmp/pod-monitor.json \
		--write-out %{http_code} --silent --output /tmp/log)
	if [[ $response -ne 200 ]]; then
                printf "${RED}[NOK]${NC}\n"
                kubectl exec -ti -n $monitor_ns $grafana_pod -- cat /tmp/log
		echo
        else
                printf "${GREEN}[OK]${NC}\n"
        fi
}

build_base_image
build_master_image
build_worker_image
create_cluster
create_resources
create_dashboards

