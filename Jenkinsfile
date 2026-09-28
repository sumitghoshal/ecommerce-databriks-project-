/*
 * CI/CD pipeline: GitHub -> Build/Test -> SonarQube -> Docker -> Trivy -> ECR -> ECS
 *
 * Prerequisites in Jenkins (see docs/JENKINS_SETUP.md):
 *   - Credentials: 'aws-creds' (AWS), 'github-creds' (Git)
 *   - Manage Jenkins > System > SonarQube servers: named exactly 'MySonarQube'
 *   - Manage Jenkins > Tools > SonarQube Scanner installations: named 'SonarScanner'
 *   - Plugins: Docker Pipeline, Pipeline: AWS Steps, SonarQube Scanner, Git
 */

pipeline {
    agent any

    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
    }

    environment {
        AWS_REGION   = 'ap-south-1'
        AWS_ACCOUNT  = '123456789012'          // <-- replace with your account id
        PROJECT      = 'ecommerce-devops'
        ECR_REGISTRY = "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
        ECR_BACKEND  = "${ECR_REGISTRY}/${PROJECT}-backend"
        ECR_FRONTEND = "${ECR_REGISTRY}/${PROJECT}-frontend"
        IMAGE_TAG    = "${env.BUILD_NUMBER}"
        ECS_CLUSTER  = "${PROJECT}-cluster"
    }

    stages {

        stage('1. Checkout') {
            steps {
                checkout scm
                sh 'git log -1 --pretty=format:"Building commit %h by %an: %s"'
            }
        }

        stage('2. Build & Unit Test') {
            steps {
                sh '''
                    set -e
                    cd backend
                    python3 -m venv .venv
                    . .venv/bin/activate
                    pip install --quiet --upgrade pip
                    pip install --quiet -r requirements-dev.txt
                    pytest tests/ -v --junitxml=../test-results.xml \
                        --cov=. --cov-report=xml:../coverage.xml
                '''
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'test-results.xml'
                }
            }
        }

        stage('3. SonarQube Code Quality') {
            steps {
                script {
                    def scannerHome = tool 'SonarScanner'
                    withSonarQubeEnv('MySonarQube') {
                        sh """
                            ${scannerHome}/bin/sonar-scanner \
                                -Dsonar.projectKey=${PROJECT}-backend \
                                -Dsonar.sources=backend \
                                -Dsonar.exclusions=backend/.venv/**,backend/tests/** \
                                -Dsonar.python.coverage.reportPaths=coverage.xml
                        """
                    }
                }
            }
        }

        stage('4. Quality Gate') {
            steps {
                // Non-blocking on purpose for a demo pipeline. Change
                // abortPipeline to true once your quality gate is tuned.
                timeout(time: 5, unit: 'MINUTES') {
                    waitForQualityGate abortPipeline: false
                }
            }
        }

        stage('5. Docker Build') {
            steps {
                sh '''
                    set -e
                    docker build -t $ECR_BACKEND:$IMAGE_TAG -t $ECR_BACKEND:latest ./backend
                    docker build -t $ECR_FRONTEND:$IMAGE_TAG -t $ECR_FRONTEND:latest ./frontend
                    docker images | grep $PROJECT | head -5
                '''
            }
        }

        stage('6. Trivy Security Scan') {
            steps {
                sh '''
                    set -e
                    mkdir -p trivy-reports

                    # Report everything, but only FAIL the build on CRITICAL.
                    trivy image --severity HIGH,CRITICAL --no-progress \
                        --format table --output trivy-reports/backend.txt \
                        $ECR_BACKEND:$IMAGE_TAG
                    trivy image --severity HIGH,CRITICAL --no-progress \
                        --format table --output trivy-reports/frontend.txt \
                        $ECR_FRONTEND:$IMAGE_TAG

                    cat trivy-reports/backend.txt
                    cat trivy-reports/frontend.txt

                    trivy image --exit-code 1 --severity CRITICAL --no-progress \
                        --ignore-unfixed $ECR_BACKEND:$IMAGE_TAG
                '''
            }
            post {
                always {
                    archiveArtifacts artifacts: 'trivy-reports/*.txt', allowEmptyArchive: true
                }
            }
        }

        stage('7. Push to ECR') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                                  credentialsId: 'aws-creds']]) {
                    sh '''
                        set -e
                        aws ecr get-login-password --region $AWS_REGION | \
                            docker login --username AWS --password-stdin $ECR_REGISTRY

                        # Both tags are required: ":latest" is what the ECS task
                        # definition pulls, ":$IMAGE_TAG" gives you a rollback target.
                        docker push $ECR_BACKEND:$IMAGE_TAG
                        docker push $ECR_BACKEND:latest
                        docker push $ECR_FRONTEND:$IMAGE_TAG
                        docker push $ECR_FRONTEND:latest
                    '''
                }
            }
        }

        stage('8. Deploy to ECS') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                                  credentialsId: 'aws-creds']]) {
                    sh '''
                        set -e
                        aws ecs update-service --cluster $ECS_CLUSTER \
                            --service backend-service --force-new-deployment \
                            --region $AWS_REGION --no-cli-pager

                        aws ecs update-service --cluster $ECS_CLUSTER \
                            --service frontend-service --force-new-deployment \
                            --region $AWS_REGION --no-cli-pager
                    '''
                }
            }
        }

        stage('9. Wait for Healthy Deployment') {
            steps {
                withCredentials([[$class: 'AmazonWebServicesCredentialsBinding',
                                  credentialsId: 'aws-creds']]) {
                    sh '''
                        set -e
                        echo "Waiting for services to stabilise (up to 10 min)…"
                        aws ecs wait services-stable \
                            --cluster $ECS_CLUSTER \
                            --services backend-service frontend-service \
                            --region $AWS_REGION
                        echo "Both services are stable."
                    '''
                }
            }
        }
    }

    post {
        success {
            echo "SUCCESS: build ${IMAGE_TAG} deployed. Rollback tag: ${IMAGE_TAG}"
        }
        failure {
            echo "FAILED at stage: ${currentBuild.result}. Check the stage log above."
        }
        always {
            sh 'docker image prune -f || true'
            cleanWs(deleteDirs: true, notFailBuild: true)
        }
    }
}
