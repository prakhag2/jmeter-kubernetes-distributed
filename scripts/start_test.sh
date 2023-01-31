#!/usr/bin/env bash
#Script created to launch Jmeter tests directly from the current terminal without accessing the jmeter master pod.
#It requires that you supply the path to the jmx file
#After execution, test script jmx file may be deleted from the pod itself but not locally.

namespace="$1"
[ -n "$namespace" ] || read -p 'Enter namespace to run the test ' namespace

jmx="$1"
[ -n "$jmx" ] || read -p 'Enter path to the jmx file ' jmx

if [ ! -f "$jmx" ];
then
    echo "Test script file was not found in PATH"
    echo "Please check and input the correct file path"
    exit
fi

test_name="$(basename "$jmx")"

## Get Master pod details
master_pod=`kubectl get po -n $namespace | grep jmeter-master | awk '{print $1}'`
kubectl cp "$jmx" -n $namespace "$master_pod:/$test_name"

## Starting Jmeter load test
workers=$(kubectl get pods --selector=jmeter_mode=slave --template '{{range .items}}{{.metadata.name}}{{"\n"}}{{end}}' -n $namespace)
workers=($workers)
kubectl exec -ti -n $namespace $master_pod -- /bin/bash /load_test "$test_name" &
PID=$!

## If any worker is abruptly lost during the run then the master keeps active threads
## and keeps running even after the test is finished. The following logic is to log
## any jmeter workers that are abruptly lost during the run.
deleted=()
while kill -0 "$PID" >/dev/null 2>&1;
do
	for worker in "${workers[@]}"
        do
                state=$(kubectl get pods $worker -n $namespace --ignore-not-found --no-headers -o custom-columns=":status.phase")
		if [[ ! " ${deleted[*]} " =~ " ${worker} " && ( -z "$state" || "$state" != "Running" ) ]]; then
                        echo "$worker down"
			deleted+=($worker)
		fi
        done
        sleep 10
done

