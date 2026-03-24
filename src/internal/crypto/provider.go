// Package crypto provides the CryptoProvider interface and its default implementation.
//
// ALL cryptographic operations in SecureVote go through this interface.
// This is the single point of change for post-quantum migration.
// No other package in the codebase imports crypto primitives directly.
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"io"

	"github.com/google/uuid"
	"golang.org/x/crypto/argon2"
)

// --- Interface ---

// Provider abstracts all cryptographic operations.
// Implementations: DefaultProvider (current), PostQuantumProvider (future).
type Provider interface {
	// Hashing
	Hash(data []byte) [32]byte
	HashHex(data []byte) string
	HashMulti(parts ...[]byte) [32]byte
	HashMultiHex(parts ...[]byte) string

	// Application-level encryption (AES-256-GCM)
	Encrypt(plaintext []byte, key []byte) (ciphertext []byte, nonce []byte, err error)
	Decrypt(ciphertext []byte, key []byte, nonce []byte) (plaintext []byte, err error)

	// Blind signatures (RSA-based)
	GenerateBlindingFactor(pubKey *rsa.PublicKey) (r []byte, rInv []byte, err error)
	BlindMessage(message []byte, r []byte, pubKey *rsa.PublicKey) ([]byte, error)
	SignBlinded(blindedMsg []byte, privKey *rsa.PrivateKey) ([]byte, error)
	UnblindSignature(blindSig []byte, rInv []byte, pubKey *rsa.PublicKey) ([]byte, error)
	VerifyUnblindedSignature(message []byte, sig []byte, pubKey *rsa.PublicKey) error

	// Password/PIN hashing (Argon2id)
	HashPassword(password string, salt []byte) string
	GenerateSalt() ([]byte, error)
	VerifyPassword(password string, salt []byte, expectedHash string) bool

	// Utilities
	GenerateNonce() ([32]byte, error)
	GenerateUUID() string
	SecureRandomBytes(n int) ([]byte, error)

	// Row integrity
	ComputeRowIntegrity(fields ...string) string
}

// --- Default Implementation ---

// DefaultProvider implements Provider using current (non-quantum) algorithms.
type DefaultProvider struct{}

// NewDefaultProvider returns a Provider using SHA-256, AES-256-GCM, RSA-2048, and Argon2id.
func NewDefaultProvider() Provider {
	return &DefaultProvider{}
}

// --- Hashing ---

func (p *DefaultProvider) Hash(data []byte) [32]byte {
	return sha256.Sum256(data)
}

func (p *DefaultProvider) HashHex(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

func (p *DefaultProvider) HashMulti(parts ...[]byte) [32]byte {
	hasher := sha256.New()
	for _, part := range parts {
		hasher.Write(part)
	}
	var result [32]byte
	copy(result[:], hasher.Sum(nil))
	return result
}

func (p *DefaultProvider) HashMultiHex(parts ...[]byte) string {
	h := p.HashMulti(parts...)
	return hex.EncodeToString(h[:])
}

// --- Application-Level Encryption (AES-256-GCM) ---

func (p *DefaultProvider) Encrypt(plaintext []byte, key []byte) ([]byte, []byte, error) {
	if len(key) != 32 {
		return nil, nil, errors.New("crypto: AES-256 requires a 32-byte key")
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, nil, fmt.Errorf("crypto: creating AES cipher: %w", err)
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, nil, fmt.Errorf("crypto: creating GCM: %w", err)
	}

	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, nil, fmt.Errorf("crypto: generating nonce: %w", err)
	}

	ciphertext := gcm.Seal(nil, nonce, plaintext, nil)
	return ciphertext, nonce, nil
}

func (p *DefaultProvider) Decrypt(ciphertext []byte, key []byte, nonce []byte) ([]byte, error) {
	if len(key) != 32 {
		return nil, errors.New("crypto: AES-256 requires a 32-byte key")
	}

	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("crypto: creating AES cipher: %w", err)
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("crypto: creating GCM: %w", err)
	}

	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return nil, fmt.Errorf("crypto: decryption failed (tampered or wrong key): %w", err)
	}

	return plaintext, nil
}

// --- Blind Signatures ---
// Full RSA blind signature implementation is complex; these are the entry points.
// The actual blinding math uses Go's crypto/rsa internals.

func (p *DefaultProvider) GenerateBlindingFactor(pubKey *rsa.PublicKey) ([]byte, []byte, error) {
	// Generate random r coprime to N, and compute r^(-1) mod N
	// This is a placeholder — production uses constant-time big.Int operations
	_ = pubKey
	return nil, nil, errors.New("crypto: blind signature implementation requires full RSA blinding (see internal/crypto/blind.go)")
}

func (p *DefaultProvider) BlindMessage(message []byte, r []byte, pubKey *rsa.PublicKey) ([]byte, error) {
	_ = message
	_ = r
	_ = pubKey
	return nil, errors.New("crypto: see blind.go for full implementation")
}

func (p *DefaultProvider) SignBlinded(blindedMsg []byte, privKey *rsa.PrivateKey) ([]byte, error) {
	_ = blindedMsg
	_ = privKey
	return nil, errors.New("crypto: see blind.go for full implementation")
}

func (p *DefaultProvider) UnblindSignature(blindSig []byte, rInv []byte, pubKey *rsa.PublicKey) ([]byte, error) {
	_ = blindSig
	_ = rInv
	_ = pubKey
	return nil, errors.New("crypto: see blind.go for full implementation")
}

func (p *DefaultProvider) VerifyUnblindedSignature(message []byte, sig []byte, pubKey *rsa.PublicKey) error {
	// Verify that sig is a valid RSA signature on message under pubKey
	hashed := sha256.Sum256(message)
	return rsa.VerifyPKCS1v15(pubKey, 0, hashed[:], sig)
}

// ParseRSAPublicKey parses a DER-encoded RSA public key.
func ParseRSAPublicKey(der []byte) (*rsa.PublicKey, error) {
	pub, err := x509.ParsePKIXPublicKey(der)
	if err != nil {
		return nil, fmt.Errorf("crypto: parsing RSA public key: %w", err)
	}
	rsaPub, ok := pub.(*rsa.PublicKey)
	if !ok {
		return nil, errors.New("crypto: key is not RSA")
	}
	return rsaPub, nil
}

// --- Password/PIN Hashing (Argon2id) ---

const (
	argonTime    = 3
	argonMemory  = 64 * 1024 // 64 MB
	argonThreads = 4
	argonKeyLen  = 32
)

func (p *DefaultProvider) HashPassword(password string, salt []byte) string {
	hash := argon2.IDKey([]byte(password), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	return hex.EncodeToString(hash)
}

func (p *DefaultProvider) GenerateSalt() ([]byte, error) {
	salt := make([]byte, 16)
	if _, err := io.ReadFull(rand.Reader, salt); err != nil {
		return nil, fmt.Errorf("crypto: generating salt: %w", err)
	}
	return salt, nil
}

func (p *DefaultProvider) VerifyPassword(password string, salt []byte, expectedHash string) bool {
	hash := p.HashPassword(password, salt)
	// Constant-time comparison to prevent timing attacks
	if len(hash) != len(expectedHash) {
		return false
	}
	result := 0
	for i := 0; i < len(hash); i++ {
		result |= int(hash[i] ^ expectedHash[i])
	}
	return result == 0
}

// --- Utilities ---

func (p *DefaultProvider) GenerateNonce() ([32]byte, error) {
	var nonce [32]byte
	if _, err := io.ReadFull(rand.Reader, nonce[:]); err != nil {
		return nonce, fmt.Errorf("crypto: generating nonce: %w", err)
	}
	return nonce, nil
}

func (p *DefaultProvider) GenerateUUID() string {
	return uuid.New().String()
}

func (p *DefaultProvider) SecureRandomBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return nil, fmt.Errorf("crypto: generating random bytes: %w", err)
	}
	return b, nil
}

// --- Row Integrity ---

// ComputeRowIntegrity computes SHA-256 over the concatenation of all field values.
// Used for the row_integrity_hash column in every database table.
func (p *DefaultProvider) ComputeRowIntegrity(fields ...string) string {
	hasher := sha256.New()
	for _, f := range fields {
		hasher.Write([]byte(f))
	}
	return hex.EncodeToString(hasher.Sum(nil))
}

// --- Memory Wiping ---

// Wipe overwrites a byte slice with zeros.
// The //go:noinline directive prevents the compiler from optimizing this away.
//
//go:noinline
func Wipe(b []byte) {
	for i := range b {
		b[i] = 0
	}
}
