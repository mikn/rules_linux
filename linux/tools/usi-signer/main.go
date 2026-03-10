package main

import (
	"bytes"
	"crypto"
	"crypto/x509"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/foxboron/go-uefi/authenticode"
	"github.com/foxboron/go-uefi/efi/util"
	"github.com/foxboron/go-uefi/pkcs7"
)

// stringsFlag is a custom flag type for accumulating multiple string values
type stringsFlag []string

func (s *stringsFlag) String() string {
	return strings.Join(*s, ",")
}

func (s *stringsFlag) Set(value string) error {
	*s = append(*s, value)
	return nil
}

func main() {
	var (
		inputFile       = flag.String("input", "", "Input USI file to sign")
		outputFile      = flag.String("output", "", "Output signed USI file")
		certFile        = flag.String("cert", "", "Signing certificate file path")
		additionalCerts stringsFlag
		keyEnvVar       = flag.String("key-env", "SIGNING_KEY", "Environment variable containing the private key")
	)
	flag.Var(&additionalCerts, "additional-cert", "Additional certificate file for chain (can be specified multiple times)")
	flag.Parse()

	if *inputFile == "" || *outputFile == "" || *certFile == "" {
		log.Fatal("Usage: usi-signer -input <input.efi> -output <output.efi> -cert <signing.crt> [-additional-cert <intermediate.crt> ...] [-key-env <KEY_VAR>]")
	}

	signingCert, err := util.ReadCertFromFile(*certFile)
	if err != nil {
		log.Fatalf("Failed to read signing certificate from %s: %v", *certFile, err)
	}
	log.Printf("Using certificate CN=%s for signing\n", signingCert.Subject.CommonName)

	var chainCerts []*x509.Certificate
	for _, certPath := range additionalCerts {
		cert, err := util.ReadCertFromFile(certPath)
		if err != nil {
			log.Fatalf("Failed to read additional certificate from %s: %v", certPath, err)
		}
		chainCerts = append(chainCerts, cert)
		log.Printf("Adding certificate CN=%s to chain\n", cert.Subject.CommonName)
	}

	keyPEM := os.Getenv(*keyEnvVar)
	if keyPEM == "" {
		log.Fatalf("Environment variable %s is not set or empty", *keyEnvVar)
	}

	key, err := privateKeyFromPEM([]byte(keyPEM))
	if err != nil {
		log.Fatalf("Failed to parse private key: %v", err)
	}

	peFile, err := os.ReadFile(*inputFile)
	if err != nil {
		log.Fatalf("Failed to read input file %s: %v", *inputFile, err)
	}

	file, err := authenticode.Parse(bytes.NewReader(peFile))
	if err != nil {
		log.Fatalf("Failed to parse PE file: %v", err)
	}

	signer, ok := key.(crypto.Signer)
	if !ok {
		log.Fatal("Private key does not implement crypto.Signer")
	}

	_, err = file.Sign(signer, signingCert, pkcs7.WithAdditionalCerts(chainCerts))
	if err != nil {
		log.Fatalf("Failed to sign file with certificate chain: %v", err)
	}

	err = os.WriteFile(*outputFile, file.Bytes(), 0644)
	if err != nil {
		log.Fatalf("Failed to write output file %s: %v", *outputFile, err)
	}

	fmt.Printf("Successfully signed %s -> %s\n", *inputFile, *outputFile)
}
