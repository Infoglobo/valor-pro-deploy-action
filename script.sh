#!/bin/bash
#set -x 
function log() {
    S=$1
    echo $S | sed 's/./& /g'
}
uses() {
    [ ! -z "${1}" ]
}

function replace(){
    if [ "$1" == "SUBDOMAIN" ]; then
        set -x
    fi      
    if [ "$#" -ne 3 ]; then
        echo $1" set default"
        sed -i 's@${'$1'}@'"\"\""'@g' $2
    else
        sed -i 's@${'$1'}@'"$2"'@g' $3
    fi
    set +x
}



export K8S_MIN_REPLICAS=1
export K8S_MAX_REPLICAS=1
export K8S_TARGET_CPUUTILIZATIONPERCENTAGE=60
export K8S_RESOURCES_LIMITS_CPU=500m
export K8S_RESOURCES_REQUESTS_CPU=200m

echo "${KUBE_CONFIG}" | base64 -d > /tmp/config

export KUBECONFIG=/tmp/config 
kubectl version
kubectl get ns

IMAGE_BASE_PATH=harbor.devops.valorpro.com.br/valor
#APPLICATION_VERSION=$(git log --format="%h" -n 1)

if  [ -z "${APPLICATION_VERSION}" ] ; then
    APPLICATION_VERSION=$(git log --format="%h" -n 1)
fi


AMBIENTE=${GITHUB_REF##*/}
AMBIENTE=${AMBIENTE,,}

if [ "$AMBIENTE" = "merge" ]; then
    AMBIENTE=${GITHUB_BASE_REF,,}
fi

echo "AMBIENTE=${AMBIENTE}"

echo ""  >> enviroments/${AMBIENTE##*/}/cm.properties
echo "APPLICATION_VERSION=$APPLICATION_VERSION" >> enviroments/${AMBIENTE##*/}/cm.properties

if  uses "${IMAGE_TAG}" ; then
    echo "usando image tag informada $IMAGE_TAG"
else
    IMAGE_TAG=$(git log --format="%h" -n 1)
    echo "usando image tag gerada $IMAGE_TAG"
fi
export IMAGE_NAME=$IMAGE_BASE_PATH/$REPO_NAME:$IMAGE_TAG       

rm -rf ./build
mkdir -p ./build
cp ./enviroments/deployment.yml ./build/deployment.yml



SECRET_FILE=enviroments/${AMBIENTE}/secrets.properties

env | grep ^$AMBIENTE | 
while IFS='=' read -r key value; do
    key="${key/#${AMBIENTE}_/}"
    if [ -z "${value}" ] || [ ${#value} -lt 3 ]; then
        value= 
    fi            
    echo $key=${value} >> $SECRET_FILE
done 

kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

kubectl delete secrets ${REPO_NAME} -n $NAMESPACE --ignore-not-found=true
if [ -f $SECRET_FILE ]; then
    kubectl create secret generic ${REPO_NAME} --from-env-file=$SECRET_FILE -n $NAMESPACE
fi

PROPERTY_FILE=enviroments/${AMBIENTE}/cm.properties
kubectl delete configmap ${REPO_NAME} -n $NAMESPACE --ignore-not-found=true
if  [ -f $PROPERTY_FILE ]; then
    export $(grep -v '^#' $PROPERTY_FILE  | xargs)
    kubectl create configmap ${REPO_NAME} --from-env-file=$PROPERTY_FILE -n $NAMESPACE
fi

if  [ -f .env ]; then
    export $(grep -v '^#' .env  | xargs)
fi

env | grep -v '^GITHUB' | grep -v '^ACTIONS_' | grep -v '^RUNNER_' | grep -v 'JENKINS' | grep -v 'KUBE_'   | sort |
while IFS='=' read -r key value; do
    if [ ! -z "$value" ]; then
        replace $key $value ./build/deployment.yml
    fi
done 
echo "****"
cat ./enviroments/${AMBIENTE}/cm.properties
echo "****"
cat ./enviroments/deployment.yml
echo "****"
cat ./build/deployment.yml
echo "****"


kubectl apply -f ./build/deployment.yml -n $NAMESPACE
