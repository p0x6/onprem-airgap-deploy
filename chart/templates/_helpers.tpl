{{/* Common labels */}}
{{- define "saleor.labels" -}}
app.kubernetes.io/part-of: saleor
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Env shared by api, worker, and the migration job.
TODO(pass 1): verify each name against saleor-platform's common.env.
EMAIL_URL=console:// keeps Django from ever attempting outbound SMTP.
*/}}
{{- define "saleor.env" -}}
- name: SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: saleor-secrets
      key: secret-key
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: saleor-secrets
      key: database-url
- name: CELERY_BROKER_URL
  value: redis://valkey:6379/1
- name: ALLOWED_HOSTS
  value: "{{ .Values.host }},localhost,127.0.0.1"
# Saleor-specific, required when DEBUG=False (found the hard way in pass 1)
- name: ALLOWED_CLIENT_HOSTS
  value: "{{ .Values.host }},localhost,127.0.0.1"
# Also required when DEBUG=False: JWT signing key (see secrets.yaml)
- name: RSA_PRIVATE_KEY
  valueFrom:
    secretKeyRef:
      name: saleor-secrets
      key: rsa-private-key
- name: PUBLIC_URL
  value: "https://{{ .Values.host }}/"
- name: DASHBOARD_URL
  value: "https://{{ .Values.host }}/dashboard/"
- name: EMAIL_URL
  value: "console://"
- name: DEBUG
  value: {{ .Values.saleor.debug | quote }}
{{- end }}
