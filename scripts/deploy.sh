#!/bin/bash

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME=${CLUSTER_NAME:-"task-management-cluster"}
AWS_REGION=${AWS_REGION:-"us-west-2"}
NAMESPACE=${NAMESPACE:-"task-management"}
IMAGE_TAG=${IMAGE_TAG:-"latest"}
ECR_REPOSITORY=${ECR_REPOSITORY:-""}

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed. Please install kubectl first."
    fi
    
    # Check if aws CLI is installed
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed. Please install AWS CLI first."
    fi
    
    # Check if docker is installed
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker first."
    fi
    
    log_success "All prerequisites are met!"
}

setup_eks_cluster() {
    log_info "Setting up EKS cluster..."
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
    
    # Verify connection
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Failed to connect to EKS cluster. Please check your configuration."
    fi
    
    log_success "Connected to EKS cluster: $CLUSTER_NAME"
}

install_aws_load_balancer_controller() {
    log_info "Installing AWS Load Balancer Controller..."
    
    # Create IAM service account for AWS Load Balancer Controller
    eksctl create iamserviceaccount \
        --cluster=$CLUSTER_NAME \
        --namespace=kube-system \
        --name=aws-load-balancer-controller \
        --role-name "AmazonEKSLoadBalancerControllerRole" \
        --attach-policy-arn=arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess \
        --override-existing-serviceaccounts \
        --approve
    
    # Install AWS Load Balancer Controller
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
    
    helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName=$CLUSTER_NAME \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        --set region=$AWS_REGION \
        --set vpcId=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.resourcesVpcConfig.vpcId" --output text)
    
    log_success "AWS Load Balancer Controller installed!"
}

create_namespace() {
    log_info "Creating namespace: $NAMESPACE"
    kubectl apply -f k8s/namespace.yaml
    log_success "Namespace created!"
}

deploy_secrets_and_config() {
    log_info "Deploying ConfigMaps and Secrets..."
    
    # Apply ConfigMaps
    kubectl apply -f k8s/configmap.yaml
    
    # Apply Secrets
    kubectl apply -f k8s/secrets.yaml
    
    log_success "ConfigMaps and Secrets deployed!"
}

deploy_storage() {
    log_info "Deploying storage resources..."
    
    # Apply StorageClass
    kubectl apply -f k8s/storage-class.yaml
    
    log_success "Storage resources deployed!"
}

deploy_databases() {
    log_info "Deploying PostgreSQL..."
    kubectl apply -f k8s/postgres-statefulset.yaml
    
    log_info "Deploying Redis..."
    kubectl apply -f k8s/redis-config.yaml
    kubectl apply -f k8s/redis-statefulset.yaml
    
    log_info "Waiting for databases to be ready..."
    kubectl wait --for=condition=ready pod -l app=postgres -n $NAMESPACE --timeout=300s
    kubectl wait --for=condition=ready pod -l app=redis -n $NAMESPACE --timeout=300s
    
    log_success "Databases deployed and ready!"
}

build_and_push_image() {
    if [ -z "$ECR_REPOSITORY" ]; then
        log_warning "ECR_REPOSITORY not set. Skipping image build and push."
        return
    fi
    
    log_info "Building and pushing Docker image..."
    
    # Get ECR login token
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPOSITORY
    
    # Build image
    docker build --target production -t task-management:$IMAGE_TAG .
    
    # Tag for ECR
    docker tag task-management:$IMAGE_TAG $ECR_REPOSITORY:$IMAGE_TAG
    
    # Push to ECR
    docker push $ECR_REPOSITORY:$IMAGE_TAG
    
    log_success "Image pushed to ECR!"
}

deploy_application() {
    log_info "Deploying FastAPI application..."
    
    # If ECR repository is set, update the image in deployment
    if [ ! -z "$ECR_REPOSITORY" ]; then
        sed -i.bak "s|image: task-management:latest|image: $ECR_REPOSITORY:$IMAGE_TAG|g" k8s/fastapi-deployment.yaml
    fi
    
    kubectl apply -f k8s/fastapi-deployment.yaml
    
    log_info "Waiting for application to be ready..."
    kubectl wait --for=condition=available deployment/task-management-api -n $NAMESPACE --timeout=300s
    
    log_success "Application deployed and ready!"
}

run_database_migrations() {
    log_info "Running database migrations..."
    
    # Create a job to run migrations
    kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migration-$(date +%s)
  namespace: $NAMESPACE
spec:
  template:
    spec:
      containers:
      - name: migration
        image: task-management:$IMAGE_TAG
        command: ["alembic", "upgrade", "head"]
        envFrom:
        - configMapRef:
            name: task-management-config
        env:
        - name: DATABASE_USER
          valueFrom:
            secretKeyRef:
              name: task-management-secrets
              key: DATABASE_USER
        - name: DATABASE_PASSWORD
          valueFrom:
            secretKeyRef:
              name: task-management-secrets
              key: DATABASE_PASSWORD
        - name: DATABASE_URL
          value: "postgresql://\$(DATABASE_USER):\$(DATABASE_PASSWORD)@\$(DATABASE_HOST):\$(DATABASE_PORT)/\$(DATABASE_NAME)"
      restartPolicy: Never
  backoffLimit: 3
EOF
    
    log_success "Database migrations completed!"
}

show_deployment_info() {
    log_info "Deployment Information:"
    echo ""
    echo "Namespace: $NAMESPACE"
    echo "Cluster: $CLUSTER_NAME"
    echo "Region: $AWS_REGION"
    echo ""
    
    log_info "Getting service information..."
    kubectl get pods,svc,pvc,ingress -n $NAMESPACE
    
    echo ""
    log_info "To access the application:"
    echo "1. Get the load balancer URL:"
    echo "   kubectl get ingress -n $NAMESPACE"
    echo ""
    echo "2. Port forward for local testing:"
    echo "   kubectl port-forward svc/task-management-api-service 8000:80 -n $NAMESPACE"
    echo ""
    echo "3. Check application logs:"
    echo "   kubectl logs -f deployment/task-management-api -n $NAMESPACE"
}

# Main deployment flow
main() {
    log_info "Starting deployment of Task Management System to EKS..."
    
    check_prerequisites
    setup_eks_cluster
    
    # Uncomment the next line if AWS Load Balancer Controller is not installed
    # install_aws_load_balancer_controller
    
    create_namespace
    deploy_secrets_and_config
    deploy_storage
    deploy_databases
    
    # Build and push image (only if ECR repository is configured)
    build_and_push_image
    
    deploy_application
    run_database_migrations
    
    show_deployment_info
    
    log_success "Deployment completed successfully! 🎉"
}

# Run main function
main "$@"