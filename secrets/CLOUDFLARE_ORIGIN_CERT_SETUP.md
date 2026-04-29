# TEMPLATE: Cloudflare Origin Certificate Secret
# 
# This Secret must be created in BOTH namespaces:
# - integration-project-2026-groep-2-dev
# - integration-project-2026-groep-2-prod
#
# To create the Secret, run:
#
# kubectl create secret tls cloudflare-origin-cert \
#   --cert=path/to/origin-cert.pem \
#   --key=path/to/origin-key.pem \
#   -n integration-project-2026-groep-2-dev
#
# kubectl create secret tls cloudflare-origin-cert \
#   --cert=path/to/origin-cert.pem \
#   --key=path/to/origin-key.pem \
#   -n integration-project-2026-groep-2-prod
#
# Or, if you have the certificate files, create it declaratively:

---
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-origin-cert
  namespace: integration-project-2026-groep-2-dev
type: kubernetes.io/tls
data:
  # Base64-encoded certificate
  tls.crt: LS0tLS1CRUdJTi... (base64-encoded origin certificate)
  # Base64-encoded private key
  tls.key: LS0tLS1CRUdJTi... (base64-encoded origin private key)

---
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-origin-cert
  namespace: integration-project-2026-groep-2-prod
type: kubernetes.io/tls
data:
  # Base64-encoded certificate
  tls.crt: LS0tLS1CRUdJTi... (base64-encoded origin certificate)
  # Base64-encoded private key
  tls.key: LS0tLS1CRUdJTi... (base64-encoded origin private key)
