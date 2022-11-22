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

echo "${KUBE_CONFIG}" | base64 -d > /tmp/config

export KUBECONFIG=/tmp/config 
kubectl version
kubectl get ns

IMAGE_BASE_PATH=harbor.devops.valorpro.com.br/valor
export REPO_NAME=${{ github.event.repository.name }}

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


AMBIENTE=${GITHUB_REF##*/}
AMBIENTE=${AMBIENTE^^}

SECRET_FILE=enviroments/${GITHUB_REF##*/}/secrets.properties

env | grep ^$AMBIENTE | 
while IFS='=' read -r key value; do
    key="${key/#${AMBIENTE}_/}"
    if [ -z "${value}" ] || [ ${#value} -lt 3 ]; then
        value= 
    fi            
    echo $key=${value} >> $SECRET_FILE
done 

kubectl delete secrets ${REPO_NAME} -n valor --ignore-not-found=true
if [ -f $SECRET_FILE ]; then
    kubectl create secret generic ${REPO_NAME} --from-env-file=$SECRET_FILE -n valor
fi

PROPERTY_FILE=enviroments/${GITHUB_REF##*/}/cm.properties
kubectl delete configmap ${REPO_NAME} -n valor --ignore-not-found=true
if  [ -f $PROPERTY_FILE ]; then
    export $(grep -v '^#' $PROPERTY_FILE  | xargs)
    kubectl create configmap ${REPO_NAME} --from-env-file=$PROPERTY_FILE -n valor
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
cat ./build/deployment.yml
echo "****"

kubectl version
kubectl apply -f ./build/deployment.yml