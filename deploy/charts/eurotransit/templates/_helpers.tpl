{{/*
Expand the name of the chart.
*/}}
{{- define "eurotransit.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Return and validate the deployment strategy for a service that supports both
Canary and Blue/Green. Invalid values fail rendering instead of silently
falling back to a different traffic path.
*/}}
{{- define "eurotransit.deploymentStrategy" -}}
{{- $strategy := index .root.Values.deploymentStrategies .service -}}
{{- if not (has $strategy (list "standard" "canary" "blueGreen")) -}}
{{- fail (printf "deploymentStrategies.%s must be one of: standard, canary, blueGreen (got %q)" .service $strategy) -}}
{{- end -}}
{{- $strategy -}}
{{- end -}}

{{/*
Number of safety samples from warm-up through the end of the observation
window, inclusive. Validation guarantees exact interval alignment.
*/}}
{{- define "eurotransit.safetyAnalysisCount" -}}
{{- $duration := include "eurotransit.durationSeconds" .duration | atoi -}}
{{- $interval := include "eurotransit.durationSeconds" .interval | atoi -}}
{{- $warmup := include "eurotransit.durationSeconds" .warmup | atoi -}}
{{- add 1 (div (sub $duration $warmup) $interval) -}}
{{- end -}}

{{/* Convert a simple Argo duration (s/m/h) into seconds for metric count. */}}
{{- define "eurotransit.durationSeconds" -}}
{{- $value := toString . -}}
{{- if hasSuffix "s" $value -}}
{{- trimSuffix "s" $value | atoi -}}
{{- else if hasSuffix "m" $value -}}
{{- mul (trimSuffix "m" $value | atoi) 60 -}}
{{- else if hasSuffix "h" $value -}}
{{- mul (trimSuffix "h" $value | atoi) 3600 -}}
{{- else -}}
{{- fail (printf "analysis duration %q must end in s, m, or h" $value) -}}
{{- end -}}
{{- end -}}

{{/* Number of readiness samples needed to cover the configured duration. */}}
{{- define "eurotransit.analysisCount" -}}
{{- $duration := include "eurotransit.durationSeconds" .duration | atoi -}}
{{- $interval := include "eurotransit.durationSeconds" .interval | atoi -}}
{{- if le $interval 0 -}}
{{- fail "progressiveDelivery.automatedAnalysis.interval must be greater than zero" -}}
{{- end -}}
{{- div $duration $interval -}}
{{- end -}}

{{/*
Validate the fail-closed analysis contract even when automation is disabled.
This prevents an invalid dormant configuration from becoming active through a
small values-only change later.
*/}}
{{- define "eurotransit.validateAutomatedAnalysis" -}}
{{- $analysis := .Values.progressiveDelivery.automatedAnalysis -}}
{{- $duration := include "eurotransit.durationSeconds" $analysis.duration | atoi -}}
{{- $interval := include "eurotransit.durationSeconds" $analysis.interval | atoi -}}
{{- $safetyWarmup := include "eurotransit.durationSeconds" $analysis.safetyWarmup | atoi -}}
{{- $safetyQueryWindow := include "eurotransit.durationSeconds" $analysis.safetyQueryWindow | atoi -}}
{{- if lt $duration 300 -}}
{{- fail "progressiveDelivery.automatedAnalysis.duration must be at least 5m (300 seconds)" -}}
{{- end -}}
{{- if or (le $interval 0) (gt $interval $duration) -}}
{{- fail "progressiveDelivery.automatedAnalysis.interval must be greater than zero and no longer than duration" -}}
{{- end -}}
{{- if ne (mod $duration $interval) 0 -}}
{{- fail "progressiveDelivery.automatedAnalysis.duration must be exactly divisible by interval" -}}
{{- end -}}
{{- if or (lt $safetyWarmup $interval) (ge $safetyWarmup $duration) -}}
{{- fail "progressiveDelivery.automatedAnalysis.safetyWarmup must be at least one interval and shorter than duration" -}}
{{- end -}}
{{- if ne (mod (sub $duration $safetyWarmup) $interval) 0 -}}
{{- fail "progressiveDelivery.automatedAnalysis.duration minus safetyWarmup must be exactly divisible by interval" -}}
{{- end -}}
{{- if lt $safetyQueryWindow $interval -}}
{{- fail "progressiveDelivery.automatedAnalysis.safetyQueryWindow must be at least one interval" -}}
{{- end -}}
{{- if lt (len $analysis.canaryWeights) 2 -}}
{{- fail "progressiveDelivery.automatedAnalysis.canaryWeights must contain at least two stages" -}}
{{- end -}}
{{- $previous := 0 -}}
{{- range $weight := $analysis.canaryWeights -}}
{{- if le ($weight | int) $previous -}}
{{- fail "progressiveDelivery.automatedAnalysis.canaryWeights must be strictly increasing" -}}
{{- end -}}
{{- $previous = $weight | int -}}
{{- end -}}
{{- if ne $previous 100 -}}
{{- fail "progressiveDelivery.automatedAnalysis.canaryWeights must end at 100" -}}
{{- end -}}
{{- $canaryAnalysisSeconds := mul $duration (len $analysis.canaryWeights) -}}
{{- $blueGreenAnalysisSeconds := mul $duration 2 -}}
{{- $maximumAnalysisSeconds := max $canaryAnalysisSeconds $blueGreenAnalysisSeconds -}}
{{- $minimumProgressDeadline := add (int $maximumAnalysisSeconds) (int .Values.progressiveDelivery.minReadySeconds) (int $analysis.progressDeadlineSafetyMarginSeconds) -}}
{{- if lt (int .Values.progressiveDelivery.progressDeadlineSeconds) (int $minimumProgressDeadline) -}}
{{- fail (printf "progressiveDelivery.progressDeadlineSeconds must be at least longest automated analysis (%d) + minReadySeconds + progressDeadlineSafetyMarginSeconds = %d seconds" $maximumAnalysisSeconds $minimumProgressDeadline) -}}
{{- end -}}
{{- $minimumScaleDown := add (int $duration) (int $analysis.postPromotionSafetyMarginSeconds) -}}
{{- if le (int .Values.progressiveDelivery.blueGreen.scaleDownDelaySeconds) (int $minimumScaleDown) -}}
{{- fail (printf "progressiveDelivery.blueGreen.scaleDownDelaySeconds must be greater than analysis duration plus postPromotionSafetyMarginSeconds (%d seconds)" $minimumScaleDown) -}}
{{- end -}}
{{- if and $analysis.services.frontend.enabled (ne .Values.deploymentStrategies.frontend "blueGreen") -}}
{{- fail "frontend automated analysis requires deploymentStrategies.frontend=blueGreen" -}}
{{- end -}}
{{- if and $analysis.services.orders.enabled (eq .Values.deploymentStrategies.orders "standard") -}}
{{- fail "orders automated analysis requires deploymentStrategies.orders to be canary or blueGreen" -}}
{{- end -}}
{{- if and $analysis.services.catalog.enabled (eq .Values.deploymentStrategies.catalog "standard") -}}
{{- fail "catalog automated analysis requires deploymentStrategies.catalog to be canary or blueGreen" -}}
{{- end -}}
{{- if and $analysis.services.inventory.enabled (not .Values.blueGreen.inventory.enabled) -}}
{{- fail "inventory automated analysis requires blueGreen.inventory.enabled=true" -}}
{{- end -}}
{{- if and $analysis.services.payments.enabled (not .Values.blueGreen.payments.enabled) -}}
{{- fail "payments automated analysis requires blueGreen.payments.enabled=true" -}}
{{- end -}}
{{- end -}}

{{/* Return true only for a service explicitly enabled in the validated map. */}}
{{- define "eurotransit.analysisEnabled" -}}
{{- index .root.Values.progressiveDelivery.automatedAnalysis.services .service "enabled" -}}
{{- end -}}

{{/* Build an immutable digest reference when supplied, otherwise preserve the existing tag behavior. */}}
{{- define "eurotransit.imageReference" -}}
{{- if .digest -}}
{{- printf "%s@%s" .repository .digest -}}
{{- else -}}
{{- printf "%s:%s" .repository .tag -}}
{{- end -}}
{{- end -}}

{{/* Progressive delivery is blocked unless CI has supplied an immutable image digest. */}}
{{- define "eurotransit.requireProgressiveDigest" -}}
{{- $digest := default "" .image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" $digest) -}}
{{- fail (printf "%s.image.digest must be an immutable sha256 digest before progressive delivery is enabled" .service) -}}
{{- end -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "eurotransit.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}
