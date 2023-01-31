# jmeter-kubernetes-distributed

The repo creates a distributed GKE setup to run jmeter tests. The setup also creates a Grafana based monitoring infrastructure - on the back of influxdb and prometheus - to monitor running test metrics and health of jmeter workers running on GKE respectively. The jmeter setup is as follows:

scripts/setup.sh does the following:
*  Allows you to create a new GKE cluster or reuse an existing cluster. It is recommended to use an isolated cluster to run jmeter master and workers.
*  Will create a user-defined namespace to create jmeter master and workers. 
*  Will create monitoring resources in a different namespace (ltmonitoring).

scripts/start_test.sh does the following:
* Takes a jmx script to initiate the load test in user-defined namespace (created as part of setup.sh). Example jmx scripts are available in "tests/"

## Scaling characteristics 
- The scaling factor comes from number of jmeter workers provisioned (as defined under slaves/jmeter_slaves_deploy.yaml). jmeter does not allow multi-master setup. Hence, if the limits of jmeter master is reached then the only option is to increase its resource requests and limits. It should be noted that the master is mostly used for orchestration and should be able to handle a fairly high number of workers. 

- The number of jmeter workers should be pre-decided and cannot be changed after the test is commenced. Each jmeter worker is configured with 1G heap on a 2G pod. It is recommended to determine the number of requests/threads each worker can support without putting a constraint on its resources (recommended CPU and MEM usage < 70%). The number of requests/threads is strictly dependent on the application. For example, if you spawn 10 threads per worker and each thread spawns a request which takes 1s to complete then the max rps that can be achieved is 10rps per worker. Each thread consumes CPU and MEM and you should make sure you do not run into CPU throttling and/or OOM while increasing thread count on the worker. Depending on the load requirements, provision the number of workers such that: 
Required RPS = RPS each worker is able to generate (with CPU and MEM < 70%) x Number of workers. 

- The load test can be horizontally scaled by replicating the jmeter master-worker setup in a different namespace. For example, let's say the required rps for the load test is 1000. You create a setup with 1 master and 10 workers in namespace "test-1". Let's say this generates 500rps during the test run. You can create one more setup with 1 master and 10 workers in a different namespace ("test-2") and re-run the test with the same jmx file (it's recommended to change the application name in the backend listener though so that both the runs can show up differently in Grafana without overriding each other).
 
![image](https://user-images.githubusercontent.com/85472520/215675410-6f69a947-c770-49c3-9c97-8adf40d9298f.png)

By adding master-workers in different namespaces you can mimic horizontal scaling of the test setup without worrying about the single master limitation. 

## How to automatically generate jmx files
If the target is a browser-based application then jmx files can be automatically generated using [Blazemeter Chrome Recorder Extension](https://guide.blazemeter.com/hc/en-us/articles/206732579-The-BlazeMeter-Chrome-Extension-Record-JMeter-Selenium-or-Synchronized-JMeter-and-Selenium) and [JMX Converter](https://converter.blazemeter.com/). Note that the produced jmx script will not be in the same form as produced in "tests/". The jmx script will not have any backend listeners and additional plugins made available in this setup. The easiest way to include these additional options is to use the [jmeter GUI](https://jmeter.apache.org/usermanual/get-started.html#running) and [jmeter plugins](https://www.blazemeter.com/blog/jmeter-plugins-manager) (described below). Move the generated test in the following structure:

![image](https://drive.google.com/uc?export=view&id=1rq6SQm6MKrtytF9Id_ZiATZHp_wz_TUn)

The setup in this repo includes some additional plugins (see Dockerfile-base) like Blazemeter Concurrency Thread Group and [Throughput Shaper Timer](https://www.blazemeter.com/blog/jmeters-shaping-timer-plugin). Under concurrency thread group, you will setup concurrent threads based on the parameters described in the previous section. Note that these parameters are set on a per worker basis. Under throughput shaper timer, you will define how rps load will look like:

![image](https://drive.google.com/uc?export=view&id=1oGW_pFOXhamYNchFLZMlmhHZvBLY7gkI)

Additionally, a backend listner also needs to be added that ties the listener to influxdb that will be created by the setup.

![image](https://drive.google.com/uc?export=view&id=1HshMNg8vRTnCFD5sqaKTeUbT0jpsfkIq)

For reference, refer /tests/online.jmx that includes all the aforementioned things.

## How to run
- Run scripts/setup.js: Will prompt for some options and automatically create underlying resources. Note that the script uses "set -e" which means it will exit on error without displaying the cause. If you see script not completely normally then remove the "set -e" option and try.
- Run scripts/start_test.sh: Start the actual test after underlying infrastructure has been created. Give relative path to the jmx file for your test.
- A Grafana monitoring service is created with 3 dashboards (under Dashboards -> General). To find the monitoring service, look at GKE -> Services (under ltmonitoring namespace).

## Things to watch out for
When the test is running, you can face 2 types of errors:
1. Jmeter worker error (you can monitor jmeter worker pods under the namespace you had chosen earlier). If the workers are abruptly and regularly shutting down then most likely you have configured higher number of threads or requests that the worker can handle. In such cases the worker will shut down if there is OOM. Alternatively if the CPU is throttled then you'll not see worker reaching the numbers you have set under Concurrency Thread Group or Throughput Shaper. 

3. Errors in load test results (Failed Requests/Errors in Grafana) as shown below:

![image](https://drive.google.com/uc?export=view&id=1XF8fs4EuPgV66C3BMOKtPk7UFa6yLc3t) 

Failed requests typically indicate application specific errors. For example, the responses might be timing out if the application isn't autoscaling quickly enough and/or pods have scheduling constraints such as cluster autoscaler reached its capacity or undergoing a scale out while requests keep coming in. Such errors will help you to right size the minimum number of pods that should be running to cater to a specific load as well as the optimum autoscaling profile.
