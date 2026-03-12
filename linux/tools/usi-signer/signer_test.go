package main

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"testing"
)

func TestPrivateKeyFromPEM_RSA(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(key),
	})

	got, err := privateKeyFromPEM(pemBytes)
	if err != nil {
		t.Fatalf("privateKeyFromPEM: %v", err)
	}
	if _, ok := got.(*rsa.PrivateKey); !ok {
		t.Errorf("got %T, want *rsa.PrivateKey", got)
	}
}

func TestPrivateKeyFromPEM_EC(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{
		Type:  "EC PRIVATE KEY",
		Bytes: der,
	})

	got, err := privateKeyFromPEM(pemBytes)
	if err != nil {
		t.Fatalf("privateKeyFromPEM: %v", err)
	}
	if _, ok := got.(*ecdsa.PrivateKey); !ok {
		t.Errorf("got %T, want *ecdsa.PrivateKey", got)
	}
}

func TestPrivateKeyFromPEM_PKCS8(t *testing.T) {
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	pemBytes := pem.EncodeToMemory(&pem.Block{
		Type:  "PRIVATE KEY",
		Bytes: der,
	})

	got, err := privateKeyFromPEM(pemBytes)
	if err != nil {
		t.Fatalf("privateKeyFromPEM: %v", err)
	}
	if _, ok := got.(ed25519.PrivateKey); !ok {
		t.Errorf("got %T, want ed25519.PrivateKey", got)
	}
}

func TestPrivateKeyFromPEM_Errors(t *testing.T) {
	t.Run("EmptyInput", func(t *testing.T) {
		_, err := privateKeyFromPEM(nil)
		if err == nil {
			t.Error("expected error for nil input")
		}
	})

	t.Run("InvalidPEM", func(t *testing.T) {
		_, err := privateKeyFromPEM([]byte("not a pem block"))
		if err == nil {
			t.Error("expected error for invalid PEM")
		}
	})

	t.Run("UnsupportedType", func(t *testing.T) {
		pemBytes := pem.EncodeToMemory(&pem.Block{
			Type:  "CERTIFICATE",
			Bytes: []byte("fake"),
		})
		_, err := privateKeyFromPEM(pemBytes)
		if err == nil {
			t.Error("expected error for unsupported PEM type")
		}
	})
}

func TestStringsFlag(t *testing.T) {
	var f stringsFlag

	if got := f.String(); got != "" {
		t.Errorf("empty stringsFlag.String() = %q, want %q", got, "")
	}

	f.Set("cert1.pem")
	f.Set("cert2.pem")

	if got := f.String(); got != "cert1.pem,cert2.pem" {
		t.Errorf("stringsFlag.String() = %q, want %q", got, "cert1.pem,cert2.pem")
	}
	if len(f) != 2 {
		t.Errorf("len = %d, want 2", len(f))
	}
}
