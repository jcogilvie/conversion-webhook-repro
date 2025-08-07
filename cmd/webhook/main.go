package main

import (
	"crypto/tls"
	"log"
	"net/http"
	"os"

	"github.com/example/webhook-conversion/pkg/webhook"
)

func main() {
	certPath := os.Getenv("TLS_CERT_FILE")
	keyPath := os.Getenv("TLS_PRIVATE_KEY_FILE")

	if certPath == "" {
		certPath = "/etc/certs/tls.crt"
	}
	if keyPath == "" {
		keyPath = "/etc/certs/tls.key"
	}

	cert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil {
		log.Fatalf("Failed to load key pair: %v", err)
	}

	server := &http.Server{
		Addr:      ":8443",
		TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}},
	}

	http.HandleFunc("/convert", webhook.HandleConvert)
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})

	log.Println("Webhook server starting on :8443")
	if err := server.ListenAndServeTLS("", ""); err != nil {
		log.Fatalf("Failed to start webhook server: %v", err)
	}
}
