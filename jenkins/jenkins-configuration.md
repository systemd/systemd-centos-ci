Notes describing current Jenkins configuration in case it needs to be redeployed.

# Manage Jenkins
## Configure System
### Global
 - \# of executors: 0

### Global Properties
 - Environment variables
    - `LANG=en_US.utf8`

### Jenkins Location
 - System Admin e-mail address: `builder@<Jenkins URL>`

### E-mail Notification
 - SMTP server: `smtp.ci.centos.org`

### GitHub Pull Request Builder
 - Credentials -> Add -> Jenkins
    - Kind: Secret Text
    - Secret: token generated at https://github.com/settings/tokens (classic token with scope: repo:status)
    - Description: GH/mrc0mmand
    - Uncheck "Auto-manage webhooks"
    - Admin list: mrc0mmand

## Configure Global Security
### Authorization
 - Matrix-based security -> Anonymous Users -> Check "Read" in the "Overall" and "Job" categories

### Markup Formatter
 - Markup Formatter: `Raw HTML`

## Manage Nodes and Clouds
### Configure Clouds
 - Kubernetes -> Kubernetes Cloud Details -> Set "Concurrency Limit" to 10

## Plugins
 - Embeddable Build Status (https://plugins.jenkins.io/embeddable-build-status)
 - GitHub Pull Request Builder (https://plugins.jenkins.io/ghprb)
 - Mailer (https://plugins.jenkins.io/mailer)
 - Naginator (https://plugins.jenkins.io/naginator)
 - OWASP Markup Formatter (https://plugins.jenkins.io/antisamy-markup-formatter)
 - Timestamper (https://plugins.jenkins.io/timestamper)
 - URL SCM (https://plugins.jenkins.io/URLSCM)
 - Workspace Cleanup (https://plugins.jenkins.io/ws-cleanup)
