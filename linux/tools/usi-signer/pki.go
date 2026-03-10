package main

import (
	"crypto/x509"
	"encoding/pem"
	"fmt"
)

// privateKeyFromPEM decodes a private key from PEM format.
// Supports PKCS#8, PKCS#1 (RSA), SEC1 (EC), and Ed25519 formats.
// Inlined from molnett.com/platform/tools/molncmd/pkg/pki to avoid
// massive transitive dependency chain (SOPS, AWS SDK, GCP SDK, etc.).
func privateKeyFromPEM(keyPEM []byte) (interface{}, error) {
	if len(keyPEM) == 0 {
		return nil, fmt.Errorf("privateKeyFromPEM: PEM data cannot be empty")
	}

	block, _ := pem.Decode(keyPEM)
	if block == nil {
		return nil, fmt.Errorf("privateKeyFromPEM: failed to decode PEM block")
	}

	switch block.Type {
	case "PRIVATE KEY":
		return x509.ParsePKCS8PrivateKey(block.Bytes)
	case "RSA PRIVATE KEY":
		return x509.ParsePKCS1PrivateKey(block.Bytes)
	case "EC PRIVATE KEY":
		return x509.ParseECPrivateKey(block.Bytes)
	case "Ed25519 PRIVATE KEY":
		return x509.ParsePKCS8PrivateKey(block.Bytes)
	default:
		return nil, fmt.Errorf("privateKeyFromPEM: unsupported PEM block type '%s'", block.Type)
	}
}
