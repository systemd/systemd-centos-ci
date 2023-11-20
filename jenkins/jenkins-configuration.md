Notes describing current Jenkins configuration in case it needs to be redeployed.

Note: most of the configuration has been translated to a yaml format parsed
by the Configuration as Code plugin. Simply copy the `jenkins.yaml` to
`/var/lib/jenkins/jenkins.yaml` and reload the configuration under
Configure System -> Configuration as Code -> Actions -> Reload existing configuration

Do ^ _after_ installing all the plugins below.

# Manage Jenkins
## Configure System
### GitHub Pull Request Builder
 - Credentials -> Add -> Jenkins
    - Kind: Secret Text
    - Secret: token generated at https://github.com/settings/tokens (classic token with scope: repo:status)
    - Description: GH/mrc0mmand

## Manage Nodes and Clouds
### Configure Clouds
 - Kubernetes -> Kubernetes Cloud Details -> Set "Concurrency Limit" to 10

## Plugins
 - ANSI Color (https://plugins.jenkins.io/ansicolor)
 - Configuration as Code (https://plugins.jenkins.io/configuration-as-code/)
 - Embeddable Build Status (https://plugins.jenkins.io/embeddable-build-status)
 - GitHub Pull Request Builder (https://plugins.jenkins.io/ghprb)
 - Mailer (https://plugins.jenkins.io/mailer)
 - Naginator (https://plugins.jenkins.io/naginator)
 - OWASP Markup Formatter (https://plugins.jenkins.io/antisamy-markup-formatter)
 - Timestamper (https://plugins.jenkins.io/timestamper)
 - URL SCM (https://plugins.jenkins.io/URLSCM)
 - Workspace Cleanup (https://plugins.jenkins.io/ws-cleanup)

## Unwanted plugins
 - Blue Ocean
 - Display URL for Blue Ocean
 - Personalization for Blue Ocean
 - ...

# Useful links & stuff
- cico-workspace image: https://quay.io/repository/centosci/cico-workspace
- cico-workspace template: https://github.com/CentOS/ansible-infra-playbooks/blob/master/templates/openshift/jenkins-ci-workspace.yml
- spawn a debug pod: `oc run cico-workspace-debug --image quay.io/centosci/cico-workspace:latest --attach=false --leave-stdin-open --tty --stdin --command -- /bin/bash`
- (re)attach: `oc exec -it cico-workspace-debug -- bash
