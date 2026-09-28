#!/bin/bash
# ===========================================================================
# One-shot local deploy: build images, push to ECR, roll ECS.
# Useful for the FIRST deploy, before Jenkins exists (ECS services sit at 0
# healthy tasks until a real :latest image exists in ECR).
#
# Usage: ./deploy.sh [aws-region]
# ===========================================================================
set -euo pipefail

REGION="${1:-ap-south-1}"
PROJECT="ecommerce-devops"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
TAG="local-$(date +%Y%m%d-%H%M%S)"

cd "$(dirname "$0")/.."

echo "==> Logging in to ECR (${REGISTRY})"
aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$REGISTRY"

echo "==> Building backend"
docker build -t "${REGISTRY}/${PROJECT}-backend:${TAG}" \
             -t "${REGISTRY}/${PROJECT}-backend:latest" ./backend

echo "==> Building frontend"
docker build -t "${REGISTRY}/${PROJECT}-frontend:${TAG}" \
             -t "${REGISTRY}/${PROJECT}-frontend:latest" ./frontend

echo "==> Pushing images"
docker push "${REGISTRY}/${PROJECT}-backend:${TAG}"
docker push "${REGISTRY}/${PROJECT}-backend:latest"
docker push "${REGISTRY}/${PROJECT}-frontend:${TAG}"
docker push "${REGISTRY}/${PROJECT}-frontend:latest"

echo "==> Forcing new ECS deployment"
aws ecs update-service --cluster "${PROJECT}-cluster" --service backend-service \
    --force-new-deployment --region "$REGION" --no-cli-pager > /dev/null
aws ecs update-service --cluster "${PROJECT}-cluster" --service frontend-service \
    --force-new-deployment --region "$REGION" --no-cli-pager > /dev/null

echo "==> Waiting for services to stabilise…"
aws ecs wait services-stable --cluster "${PROJECT}-cluster" \
    --services backend-service frontend-service --region "$REGION"

echo "==> Deployed. Application URL:"
terraform -chdir=terraform output -raw application_url 2>/dev/null || \
    echo "   (run: terraform -chdir=terraform output application_url)"
