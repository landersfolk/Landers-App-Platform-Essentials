{{- define "landers-app.name" -}}
{{- default .Release.Name .Values.nameOverride -}}
{{- end -}}

{{- define "landers-app.labels" -}}
app: {{ include "landers-app.name" . }}
{{- end -}}
