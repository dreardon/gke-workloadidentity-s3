# GKE Accessing AWS S3 with Workload Identity Federation


## Overview

This project sets up a Google Cloud GKE cluster with Workload Identity which assumes an AWS Role in order to list data in an AWS S3 bucket.

This repository borrows heavily from the following sites:
- [Access AWS using a Google Cloud Platform native workload identity](https://aws.amazon.com/blogs/security/access-aws-using-a-google-cloud-platform-native-workload-identity/)
- [Cross-cloud identities between GCP and AWS from GKE and/or EKS](https://jason-umiker.medium.com/cross-cloud-identities-between-gcp-and-aws-from-gke-and-or-eks-182652bddadb)
- [Sourcing credentials with an external process in the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sourcing-external.html)

## Google Disclaimer
This is not an officially supported Google product

## Setup Environment
```bash
#Setup Environment variables
export ORGANIZATION_ID= #e.g. 123456789876
export PROJECT_NAME= #e.g. gke-s3
export REGION= #e.g. us-central1
export BILLING_ACCOUNT= #e.g. 111111-222222-333333
export GKE_CLUSTER= #e.g. gke-s3
export REGION= #e.g. us-central1
export ZONE= #e.g. us-central1-c
export NETWORK_NAME= #e.g. demo-network
export SUBNET_RANGE= #e.g. 10.128.0.0/20 
export GSA_NAME= #e.g. s3-gsa
export K8S_SA_NAME= #e.g. s3-ksa
export K8S_NAMESPACE= #e.g. default
export AWS_ACCOUNT_ID= #e.g. 123456789123

#Create Project
gcloud config unset project
gcloud config unset billing/quota_project
printf 'Y' | gcloud projects create --name=$PROJECT_NAME --organization=$ORGANIZATION_ID
while [ -z "$PROJECT_ID" ]; do
  export PROJECT_ID=$(gcloud projects list --filter=name:$PROJECT_NAME --format 'value(PROJECT_ID)')
done
export PROJECT_NUMBER=$(gcloud projects list --filter=id:$PROJECT_ID --format 'value(PROJECT_NUMBER)')
printf 'y' |  gcloud beta billing projects link $PROJECT_ID --billing-account=$BILLING_ACCOUNT

gcloud config set project $PROJECT_ID
printf 'Y' | gcloud config set compute/region $REGION
gcloud config set billing/quota_project $PROJECT_ID

#Enable APIs
printf 'y' |  gcloud services enable compute.googleapis.com --project $PROJECT_ID
printf 'y' |  gcloud services enable container.googleapis.com --project $PROJECT_ID
printf 'y' |  gcloud services enable gkehub.googleapis.com --project $PROJECT_ID
printf 'y' |  gcloud services enable cloudresourcemanager.googleapis.com --project $PROJECT_ID
printf 'y' |  gcloud services enable cloudbuild.googleapis.com --project $PROJECT_ID

gcloud auth application-default set-quota-project $PROJECT_ID
```

## Setup Network
```bash
#Setup Network
gcloud compute networks create $NETWORK_NAME \
    --project=$PROJECT_ID \
    --subnet-mode=custom 
gcloud compute networks subnets create $NETWORK_NAME-subnet \
    --project=$PROJECT_ID \
    --network=$NETWORK_NAME \
    --range=$SUBNET_RANGE \
    --region=$REGION

#Setup NAT
gcloud compute routers create nat-router \
  --project=$PROJECT_ID \
  --network $NETWORK_NAME \
  --region $REGION
gcloud compute routers nats create nat-config \
  --router-region $REGION \
  --project=$PROJECT_ID \
  --router nat-router \
  --nat-all-subnet-ip-ranges \
  --auto-allocate-nat-external-ips
  ```

## Setup GKE
```bash
gcloud container clusters create-auto $GKE_CLUSTER \
  --region=$REGION \
  --project=$PROJECT_ID \
  --enable-private-nodes \
  --network=$NETWORK_NAME \
  --subnetwork=$NETWORK_NAME-subnet \
  --master-ipv4-cidr "172.16.1.0/28" \
  --enable-dns-access \
  --enable-fleet \
  --enable-secret-manager \
  --security-posture=enterprise \
  --workload-vulnerability-scanning=enterprise

MY_IPV4=$(curl -s ipinfo.io/ip)
gcloud container clusters update $GKE_CLUSTER \
  --project=$PROJECT_ID \
  --enable-master-authorized-networks \
  --master-authorized-networks $MY_IPV4/32 \
  --region $REGION

gcloud container clusters get-credentials $GKE_CLUSTER \
  --region $REGION \
  --project $PROJECT_ID \
  --dns-endpoint
```

## Setup Identities
```bash
gcloud iam service-accounts create $GSA_NAME \
    --display-name="AWS S3 Service Account"

export GSA_EMAIL=$(gcloud iam service-accounts list --filter="displayName:AWS S3 Service Account" --format='value(email)')
export GSA_UNIQUE_ID=$(gcloud iam service-accounts describe $GSA_EMAIL --format='value(uniqueId)')

kubectl create serviceaccount $K8S_SA_NAME --namespace $K8S_NAMESPACE

gcloud iam service-accounts add-iam-policy-binding $GSA_EMAIL \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:$PROJECT_ID.svc.id.goog[$K8S_NAMESPACE/$K8S_SA_NAME]"

kubectl annotate serviceaccount $K8S_SA_NAME \
    --namespace $K8S_NAMESPACE \
    iam.gke.io/gcp-service-account=$GSA_EMAIL
```

## Build Container
```bash
## Setup Artifact Registry
gcloud artifacts repositories create example-repo \
  --project=$PROJECT_ID \
  --repository-format=docker \
  --location=$REGION \
  --allow-vulnerability-scanning \
  --description="GKE Quickstart Sample App"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member "serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
  --role "roles/storage.admin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member "serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
    --role="roles/logging.logWriter"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member "serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
    --role="roles/artifactregistry.writer"

gcloud builds submit \
  --region=$REGION \
  --tag $REGION-docker.pkg.dev/$PROJECT_ID/example-repo/aws-exec:latest
```

## Configure AWS Role
#### Name: S3_GKE_minimal_role (e.g. arn:aws:iam::$AWS_ACCOUNT_ID:role/S3_GKE_minimal_role)
### AWS Example Policy for S3 Access
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "s3:ListAllMyBuckets",
            "Resource": "*"
        }
    ]
}
```

### AWS Example Policy for S3 Access
```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {"Federated": "accounts.google.com"},
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "accounts.google.com:aud": "[GSA_UNIQUE_ID]"
                }
            }
        }
    ]
}
```

## Deploy Sample Container
```bash
export ROLE_ARN=arn:aws:iam::$AWS_ACCOUNT_ID:role/S3_GKE_minimal_role
export IMAGE_REFERENCE=$REGION-docker.pkg.dev/$PROJECT_ID/example-repo/aws-exec:latest

sed -i '' "s#\[IMAGE_REFERENCE\]#${IMAGE_REFERENCE}#g" deployment.yaml

kubectl apply -f ./deployment.yaml

POD_NAME=$(kubectl get pods -l app=aws-exec -o jsonpath='{.items[0].metadata.name}')
kubectl logs $POD_NAME
kubectl exec -it $POD_NAME  -- /bin/sh

#Validate
python main.py
aws s3 ls --profile S3ReadOnlyAccess
```

## Clean Up
```bash
kubectl delete -f ./deployment.yaml

```