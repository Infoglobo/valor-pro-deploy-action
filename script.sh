#!/bin/bash
set -x 
function log() {
    S=$1
    echo $S | sed 's/./& /g'
}

function s_sanitizer() {
    S=$(echo $1 | xargs)
    echo $S    
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

function slack_enunciate(){
    echo "SLACK_WEBHOOK_URL"
    log "$SLACK_WEBHOOK_URL"



    if [ ! -z "$SLACK_WEBHOOK_URL" ]; then
        #GITHUB_COMMIT_MESSAGE="$(s_sanitizer $GITHUB_COMMIT_MESSAGE)"
        GITHUB_COMMIT_MESSAGE=$(git show -s --format=%B)
        echo $GITHUB_COMMIT_MESSAGE
 
        echo '
        {
            "blocks": [
                {
                    "type": "section",
                    "text": {
                        "type": "mrkdwn",
                        "text": "Aplicação publicada *'$GITHUB_REPOSITORY'*"
                    }
                },
                {
                    "type": "section",
                    "fields": [
                        {
                            "type": "mrkdwn",
                            "text": "*Ator:*\n'$GITHUB_ACTOR'"
                        },
                        {
                            "type": "mrkdwn",
                            "text": "*Versão:*\n'$APPLICATION_VERSION'"
                        },
                        {
                            "type": "mrkdwn",
                            "text": "*Data/Hora:*\n'$D'"
                        },
                        {
                            "type": "mrkdwn",
                            "text": "*Commit:*\n'$GITHUB_COMMIT_MESSAGE'."
                        },
                        {
                            "type": "mrkdwn",
                            "text": "*Ambiente:*\n'$AMBIENTE'"
                        },
                        {
                            "type": "mrkdwn",
                            "text": "*Status da Aplicação:*\n'$APP_STATUS'"
                        }
                    ]
                }
            ]
        }
        ' > dummyfile.txt

        sed -i $'N;s/[\\n\r\']//g' dummyfile.txt 
        cat dummyfile.txt
        set -x 
        curl -v -X POST -H 'Content-type: application/json' --data "@dummyfile.txt" "$SLACK_WEBHOOK_URL"
    fi
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

sleep 5
echo "*********** git" 

printf  "\GITHUB_TOKEN --> %s\n" "$GITHUB_TOKEN"

#git remote set-url origin https://x-access-token:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY
git remote -v
git -c versionsort.suffix=- ls-remote --exit-code --refs --sort=version:refname --tags | tail --lines=1 | cut --delimiter=/ --fields=3 


echo "*********** git"
sleep 5

IMAGE_BASE_PATH=harbor.devops.valorpro.com.br/valor
#APPLICATION_VERSION=$(git log --format="%h" -n 1)




# se a variavel não prenchida na pipeline, usar o commit 
if  [ -z "${APPLICATION_VERSION}" ] ; then
    APPLICATION_VERSION=$(git log --format="%h" -n 1)
fi


GITHUB_REF_NAME=${GITHUB_REF_NAME##*/}
if [ "$GITHUB_REF_NAME" == "master" ] || [ "$GITHUB_REF_NAME" == "main"  ]; then
    APPLICATION_VERSION=$(git -c 'versionsort.suffix=-'     ls-remote --exit-code --refs --sort='version:refname' --tags    | tail --lines=1     | cut --delimiter='/' --fields=3)
else 
     APPLICATION_VERSION=$(git log --format="%h" -n 1)
fi


AMBIENTE=${GITHUB_REF_NAME##*/}
AMBIENTE=${AMBIENTE,,}

if [ "$AMBIENTE" = "merge" ]; then
    AMBIENTE=${GITHUB_BASE_REF,,}
fi



SECRETS_PREFIX=${AMBIENTE^^}

if [ "$GITHUB_REF_NAME" = "dev" ] ; then
    SECRETS_PREFIX="DEV"
elif [ "$GITHUB_REF_NAME" = "homolog" ] ; then
    SECRETS_PREFIX="HML"
elif [ "$GITHUB_REF_NAME" == "master" ] || [ "$GITHUB_REF_NAME" == "main"  ] ; then
    SECRETS_PREFIX="PRD"
    #garantir que a pasta seja sempre enviroments/main
    AMBIENTE="main"
fi  
SECRETS_PREFIX=${SECRETS_PREFIX^^}


echo "AMBIENTE=$AMBIENTE"
echo "SECRETS_PREFIX=${SECRETS_PREFIX}"
echo "APPLICATION_VERSION=${APPLICATION_VERSION}"

#garante que o arquivo de properties esta zerado.
echo ""  >> enviroments/"${AMBIENTE##*/}"/cm.properties
echo "APPLICATION_VERSION=$APPLICATION_VERSION" >> enviroments/"${AMBIENTE##*/}"/cm.properties

if  uses "${IMAGE_TAG}" ; then
    echo "usando image tag informada $IMAGE_TAG"
else
    IMAGE_TAG=$(git log --format="%h" -n 1)
    echo "usando image tag gerada $IMAGE_TAG"
fi
export IMAGE_NAME=$IMAGE_BASE_PATH/"$REPO_NAME":$IMAGE_TAG       

rm -rf ./build
mkdir -p ./build
cp ./enviroments/deployment.yml ./build/deployment.yml


#garante que o arquivo de properties esta zerado.
echo ""  >> enviroments/"${AMBIENTE##*/}"/cm.properties
SECRET_FILE=enviroments/"$AMBIENTE"/secrets.properties


env | grep ^"$SECRETS_PREFIX" | 
while IFS='=' read -r key value; do
    key="${key/#${SECRETS_PREFIX}_/}"
    if [ -z "${value}" ] || [ ${#value} -lt 3 ]; then
        value= 
    fi            
    echo "$key"="${value}" >> "$SECRET_FILE"
done 

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl delete secrets "$REPO_NAME" -n "$NAMESPACE" --ignore-not-found=true
if [ -s "$SECRET_FILE" ]; then
    #cat "$SECRET_FILE"
    kubectl create secret generic "$REPO_NAME" --from-env-file="$SECRET_FILE" -n "$NAMESPACE"
    kubectl get secrets valor-pro-identity-api -n "$NAMESPACE" -o json | jq -r '.data|map_values(@base64d)|to_entries[]|"\(.key)=\(.value)"'
fi

PROPERTY_FILE=enviroments/"$AMBIENTE"/cm.properties
kubectl delete configmap "$REPO_NAME" -n "$NAMESPACE" --ignore-not-found=true
if  [ -s "$PROPERTY_FILE" ]; then
    export $(grep -v '^#' "$PROPERTY_FILE"  | xargs)
    #cat "$PROPERTY_FILE"
    kubectl create configmap "$REPO_NAME" --from-env-file="$PROPERTY_FILE" -n "$NAMESPACE"

    kubectl get configmaps "$REPO_NAME" -n "$NAMESPACE" -o json | jq -r '.data|to_entries[]|"\(.key)=\(.value)"'
fi

if  [ -f .env ]; then
    export $(grep -v '^#' .env  | xargs)
fi

env | grep -v '^GITHUB' | grep -v '^ACTIONS_' | grep -v '^RUNNER_' | grep -v 'JENKINS' | grep -v 'KUBE_'   | sort |
while IFS='=' read -r key value; do
    if [ ! -z "$value" ]; then
        replace "$key" "$value" ./build/deployment.yml
    fi
done 
echo "****"
cat ./enviroments/"$AMBIENTE"/cm.properties
echo "****"
cat ./enviroments/deployment.yml
echo "****"
cat ./build/deployment.yml
echo "****"


kubectl apply -f ./build/deployment.yml -n "$NAMESPACE"

sleep 5
D=$(date '+%d-%m-%Y-%H:%M')
APP_STATUS=$(kubectl get pods -l app="$REPO_NAME" -n "$NAMESPACE" | tail -1 | awk '{print $3}')
set -x


#curl -v -X POST -H 'Content-type: application/json' --data '{"text": "Aplicação *'$GITHUB_REPOSITORY'* deployada no ambiente *'$AMBIENTE'* por *'$GITHUB_ACTOR'* em '$D'.", "icon_emoji": ":rocket:"}' $VALOR_PRO_SLACK_WEBHOOK_URL

slack_enunciate

