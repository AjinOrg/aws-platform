{{/* Common labels on every object */}}
{{- define "my-app.labels" -}}
app.kubernetes.io/name: my-app
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ required "image.tag is required" .Values.image.tag | quote }}
app.kubernetes.io/part-of: aws-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
environment: {{ .Values.environment }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Labels used to select the pods (must never change after the first deploy) */}}
{{- define "my-app.selectorLabels" -}}
app.kubernetes.io/name: my-app
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
