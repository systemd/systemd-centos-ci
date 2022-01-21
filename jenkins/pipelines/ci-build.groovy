// vi: sw=4 ts=4 et:

pipeline {
    agent {
        label 'cico-workspace'
    }

    options {
        timestamps()
    }

    stages {
        stage('Build & test') {
            steps {
                sh '''
                    ARGS=()

                    if [ "$ghprbPullId" ]; then
                        ARGS+=("--ci-pr" "$ghprbPullId")
                    fi

                    echo "helooooo"
                    mkdir artifacts_xyz
                    echo "ayyyy" >artifacts_xyz/hello.txt
                    #./agent-control.py --version 8-stream --kdump-collect ${ARGS:+"${ARGS[@]}"}
                '''
            }
        }
    }

    post {
        always {
            archiveArtifacts allowEmptyArchive: true, artifacts: "artifacts_*/,index.html*"
            step([$class: 'Mailer', notifyEveryUnstableBuild: true, recipients: 'frantisek+jenkins@sumsal.cz'])
        }
    }
}
