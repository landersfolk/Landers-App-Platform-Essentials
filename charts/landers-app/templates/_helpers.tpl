{{- define "landers-app.name" -}}
{{- default .Release.Name .Values.nameOverride -}}
{{- end -}}

{{- /*
Standard Kubernetes recommended labels, plus the original "app" label kept
first and unchanged -- Deployment's selector.matchLabels and Service's
selector both pin on "app" alone and MUST NOT change (selectors are
immutable on an existing Deployment, and changing the Service selector would
stop routing to already-running pods). Since a label selector only needs to
match a SUBSET of an object's labels, everything added below is purely
additive and safe to roll out onto already-deployed resources.
*/ -}}
{{- define "landers-app.labels" -}}
app: {{ include "landers-app.name" . }}
app.kubernetes.io/name: {{ include "landers-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
