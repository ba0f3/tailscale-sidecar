package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
)

var (
	runtimeScheme = runtime.NewScheme()
	codecs        = serializer.NewCodecFactory(runtimeScheme)
	deserializer  = codecs.UniversalDeserializer()
)

func init() {
	_ = corev1.AddToScheme(runtimeScheme)
	_ = admissionv1.AddToScheme(runtimeScheme)
}

type patchOperation struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

func main() {
	certPath := getEnv("TLS_CERT", "/etc/webhook/certs/tls.crt")
	keyPath := getEnv("TLS_KEY", "/etc/webhook/certs/tls.key")
	port := getEnv("PORT", "8443")

	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", mutateHandler)
	mux.HandleFunc("/health", healthHandler)

	server := &http.Server{
		Addr:    fmt.Sprintf(":%s", port),
		Handler: mux,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
	}

	log.Printf("Starting webhook server on port %s", port)
	if err := server.ListenAndServeTLS(certPath, keyPath); err != nil {
		log.Fatalf("Failed to start server: %v", err)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("OK"))
}

func mutateHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("Error reading request body: %v", err)
		http.Error(w, "Error reading request body", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	var admissionReview admissionv1.AdmissionReview
	if _, _, err := deserializer.Decode(body, nil, &admissionReview); err != nil {
		log.Printf("Error decoding admission review: %v", err)
		http.Error(w, fmt.Sprintf("Error decoding admission review: %v", err), http.StatusBadRequest)
		return
	}

	pod := &corev1.Pod{}
	if err := json.Unmarshal(admissionReview.Request.Object.Raw, pod); err != nil {
		log.Printf("Error unmarshaling pod: %v", err)
		http.Error(w, fmt.Sprintf("Error unmarshaling pod: %v", err), http.StatusBadRequest)
		return
	}

	// Check if pod has the injection label
	injectLabel := pod.Labels["tailscale.com/inject"]
	if injectLabel != "true" {
		log.Printf("Pod %s/%s does not have tailscale.com/inject=true label, skipping", pod.Namespace, pod.Name)
		sendAdmissionResponse(w, &admissionReview, nil, true, "Pod does not require sidecar injection")
		return
	}

	// Check if sidecar already exists (check for ts-sidecar or ts-sidecar-* pattern)
	sidecarName := getSidecarName(pod)
	for _, container := range pod.Spec.Containers {
		if container.Name == "ts-sidecar" || container.Name == sidecarName {
			log.Printf("Pod %s/%s already has sidecar container (%s), skipping", pod.Namespace, pod.Name, container.Name)
			sendAdmissionResponse(w, &admissionReview, nil, true, "Sidecar already exists")
			return
		}
	}

	log.Printf("Injecting Tailscale sidecar into pod %s/%s", pod.Namespace, pod.Name)

	// Generate patch operations
	patches := generateSidecarPatch(pod)

	patchBytes, err := json.Marshal(patches)
	if err != nil {
		log.Printf("Error marshaling patch: %v", err)
		http.Error(w, fmt.Sprintf("Error marshaling patch: %v", err), http.StatusInternalServerError)
		return
	}

	patchType := admissionv1.PatchTypeJSONPatch
	sendAdmissionResponse(w, &admissionReview, patchBytes, true, "Sidecar injected successfully", &patchType)
}

func getSidecarName(pod *corev1.Pod) string {
	// Generate unique sidecar name with suffix to avoid Headscale name collision
	// Format: ts-sidecar-<namespace>-<pod-name> (truncated to valid k8s name length)
	suffix := fmt.Sprintf("%s-%s", pod.Namespace, pod.Name)
	// Kubernetes container names must be <= 63 chars and match DNS-1123 subdomain
	// ts-sidecar is 10 chars, so we have 53 chars for suffix
	maxSuffixLen := 53
	if len(suffix) > maxSuffixLen {
		suffix = suffix[:maxSuffixLen]
	}
	// Remove invalid characters and ensure it starts/ends with alphanumeric
	suffix = sanitizeK8sName(suffix)
	return fmt.Sprintf("ts-sidecar-%s", suffix)
}

func sanitizeK8sName(name string) string {
	// Kubernetes names must be lowercase alphanumeric or '-', and start/end with alphanumeric
	result := ""
	for _, r := range name {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' {
			result += string(r)
		} else if r >= 'A' && r <= 'Z' {
			result += string(r + 32) // convert to lowercase
		} else {
			result += "-" // replace invalid chars with dash
		}
	}
	// Remove consecutive dashes and ensure it doesn't start/end with dash
	for len(result) > 0 && result[0] == '-' {
		result = result[1:]
	}
	for len(result) > 0 && result[len(result)-1] == '-' {
		result = result[:len(result)-1]
	}
	// Ensure it starts with alphanumeric
	if len(result) > 0 && (result[0] < 'a' || result[0] > 'z') && (result[0] < '0' || result[0] > '9') {
		result = "x" + result
	}
	return result
}

func interpolateTemplate(template string, pod *corev1.Pod) string {
	// Replace template variables with actual values
	result := template
	result = strings.ReplaceAll(result, "{{NAMESPACE}}", pod.Namespace)
	result = strings.ReplaceAll(result, "{{POD_NAME}}", pod.Name)
	result = strings.ReplaceAll(result, "{{POD_UID}}", string(pod.UID))
	return result
}

func sanitizeSecretName(name string) string {
	// Kubernetes secret names must be valid DNS-1123 subdomain
	// Convert to lowercase and replace invalid characters
	result := strings.ToLower(name)

	// Replace invalid characters with dashes (keep only alphanumeric, dashes, and dots)
	var builder strings.Builder
	for _, r := range result {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' || r == '.' {
			builder.WriteRune(r)
		} else {
			builder.WriteRune('-')
		}
	}
	result = builder.String()

	// Remove consecutive dashes and dots
	for strings.Contains(result, "--") {
		result = strings.ReplaceAll(result, "--", "-")
	}
	for strings.Contains(result, "..") {
		result = strings.ReplaceAll(result, "..", ".")
	}
	for strings.Contains(result, "-.") {
		result = strings.ReplaceAll(result, "-.", ".")
	}
	for strings.Contains(result, ".-") {
		result = strings.ReplaceAll(result, ".-", "-")
	}

	// Remove leading/trailing dashes and dots
	result = strings.Trim(result, "-.")

	// Ensure it starts and ends with alphanumeric
	if len(result) == 0 {
		result = "tailscale-secret"
	} else {
		// Check first character
		first := result[0]
		if !((first >= 'a' && first <= 'z') || (first >= '0' && first <= '9')) {
			result = "x" + result
		}
		// Check last character
		last := result[len(result)-1]
		if !((last >= 'a' && last <= 'z') || (last >= '0' && last <= '9')) {
			result = result + "x"
		}
	}

	// Limit length to 253 characters (Kubernetes limit)
	if len(result) > 253 {
		result = result[:253]
		// Ensure it still ends with alphanumeric after truncation
		last := result[len(result)-1]
		if !((last >= 'a' && last <= 'z') || (last >= '0' && last <= '9')) {
			result = result[:len(result)-1] + "x"
		}
	}

	return result
}

func generateSidecarPatch(pod *corev1.Pod) []patchOperation {
	patches := []patchOperation{}

	// Get TS_KUBE_SECRET pattern from environment or use default
	tsKubeSecretPattern := getEnv("TS_KUBE_SECRET", fmt.Sprintf("tailscale-%s-%s", pod.Namespace, pod.Name))

	// Interpolate template variables and sanitize the secret name
	tsKubeSecret := interpolateTemplate(tsKubeSecretPattern, pod)
	tsKubeSecret = sanitizeSecretName(tsKubeSecret)

	// Get TS_EXTRA_ARGS from environment (can be set via ConfigMap/EnvVar in deployment)
	tsExtraArgs := getEnv("TS_EXTRA_ARGS", "")

	// Generate unique sidecar name
	sidecarName := getSidecarName(pod)

	// Generate unique hostname for Headscale to avoid name collision
	// Format: <pod-name>-<namespace> (sanitized for Tailscale hostname)
	hostnameRaw := fmt.Sprintf("%s-%s", pod.Name, pod.Namespace)
	if len(hostnameRaw) > 63 {
		hostnameRaw = hostnameRaw[:63]
	}
	hostname := sanitizeK8sName(hostnameRaw)

	// Create sidecar container
	sidecarContainer := corev1.Container{
		Name:            sidecarName,
		Image:           "ghcr.io/tailscale/tailscale:latest",
		ImagePullPolicy: corev1.PullAlways,
		Env: []corev1.EnvVar{
			{
				Name:  "TS_EXTRA_ARGS",
				Value: tsExtraArgs,
			},
			{
				Name:  "TS_HOSTNAME",
				Value: hostname,
			},
			{
				Name:  "TS_KUBE_SECRET",
				Value: tsKubeSecret,
			},
			{
				Name:  "TS_USERSPACE",
				Value: "false",
			},
			{
				Name:  "TS_DEBUG_FIREWALL_MODE",
				Value: "auto",
			},
			{
				Name: "TS_AUTHKEY",
				ValueFrom: &corev1.EnvVarSource{
					SecretKeyRef: &corev1.SecretKeySelector{
						LocalObjectReference: corev1.LocalObjectReference{
							Name: "tailscale-auth",
						},
						Key:      "TS_AUTHKEY",
						Optional: boolPtr(true),
					},
				},
			},
			{
				Name: "POD_NAME",
				ValueFrom: &corev1.EnvVarSource{
					FieldRef: &corev1.ObjectFieldSelector{
						FieldPath: "metadata.name",
					},
				},
			},
			{
				Name: "POD_UID",
				ValueFrom: &corev1.EnvVarSource{
					FieldRef: &corev1.ObjectFieldSelector{
						FieldPath: "metadata.uid",
					},
				},
			},
		},
		SecurityContext: &corev1.SecurityContext{
			Privileged: boolPtr(true),
		},
	}

	// Add sidecar container
	patches = append(patches, patchOperation{
		Op:    "add",
		Path:  "/spec/containers/-",
		Value: sidecarContainer,
	})

	return patches
}

func sendAdmissionResponse(w http.ResponseWriter, admissionReview *admissionv1.AdmissionReview, patch []byte, allowed bool, message string, patchType ...*admissionv1.PatchType) {
	response := &admissionv1.AdmissionResponse{
		UID:     admissionReview.Request.UID,
		Allowed: allowed,
		Result: &metav1.Status{
			Message: message,
		},
	}

	if len(patch) > 0 {
		response.Patch = patch
		if len(patchType) > 0 && patchType[0] != nil {
			response.PatchType = patchType[0]
		} else {
			pt := admissionv1.PatchTypeJSONPatch
			response.PatchType = &pt
		}
	}

	admissionReview.Response = response
	admissionReview.Request = nil

	respBytes, err := json.Marshal(admissionReview)
	if err != nil {
		log.Printf("Error marshaling admission response: %v", err)
		http.Error(w, fmt.Sprintf("Error marshaling admission response: %v", err), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write(respBytes)
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func boolPtr(b bool) *bool {
	return &b
}
