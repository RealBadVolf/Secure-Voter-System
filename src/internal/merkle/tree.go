// Package merkle implements Merkle tree construction, proof generation,
// and verification for SecureVote's vote immutability layer.
//
// Each precinct's votes form a Merkle tree. The tree root is the single
// hash that represents every vote in that precinct. Changing any vote
// changes the root, making tampering detectable.
package merkle

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/securevote/securevote/pkg/models"
)

// --- Errors ---

var (
	ErrEmptyLeaves    = errors.New("merkle: cannot build tree from empty leaf set")
	ErrLeafNotFound   = errors.New("merkle: leaf not found in tree")
	ErrInvalidProof   = errors.New("merkle: proof verification failed")
	ErrRootMismatch   = errors.New("merkle: computed root does not match expected root")
)

// --- Tree Construction ---

// Tree is an in-memory Merkle tree built from vote record hashes.
type Tree struct {
	// Levels[0] = leaves, Levels[len-1] = root
	Levels [][]string

	// Leaf-to-index mapping for fast proof generation
	leafIndex map[string]int

	// Metadata
	LeafCount  int
	Depth      int
	Root       string
	BuiltAt    time.Time
	BuildTimeMs int64
}

// BuildTree constructs a Merkle tree from a slice of leaf hashes.
//
// The genesis BDF hash is prepended as the first leaf, binding the
// ballot definition to the tree. Any change to the BDF invalidates
// the entire tree.
//
// If the leaf count is odd, the last leaf is duplicated to make it even.
// This is standard Merkle tree construction.
func BuildTree(genesisBDFHash string, leafHashes []string) (*Tree, error) {
	if len(leafHashes) == 0 {
		return nil, ErrEmptyLeaves
	}

	start := time.Now()

	// Prepend the BDF hash as the genesis leaf
	allLeaves := make([]string, 0, len(leafHashes)+1)
	allLeaves = append(allLeaves, genesisBDFHash)
	allLeaves = append(allLeaves, leafHashes...)

	// Build leaf-to-index mapping
	leafIndex := make(map[string]int, len(allLeaves))
	for i, h := range allLeaves {
		leafIndex[h] = i
	}

	// Build tree level by level
	levels := [][]string{allLeaves}
	currentLevel := allLeaves

	for len(currentLevel) > 1 {
		nextLevel := make([]string, 0, (len(currentLevel)+1)/2)

		for i := 0; i < len(currentLevel); i += 2 {
			left := currentLevel[i]
			right := left // Duplicate last if odd
			if i+1 < len(currentLevel) {
				right = currentLevel[i+1]
			}

			// Parent = SHA-256(left || right)
			parentHash := hashPair(left, right)
			nextLevel = append(nextLevel, parentHash)
		}

		levels = append(levels, nextLevel)
		currentLevel = nextLevel
	}

	elapsed := time.Since(start)

	return &Tree{
		Levels:      levels,
		leafIndex:   leafIndex,
		LeafCount:   len(allLeaves),
		Depth:       len(levels) - 1,
		Root:        levels[len(levels)-1][0],
		BuiltAt:     time.Now(),
		BuildTimeMs: elapsed.Milliseconds(),
	}, nil
}

// hashPair computes SHA-256(leftHex || rightHex) where inputs are hex strings.
func hashPair(leftHex, rightHex string) string {
	left, _ := hex.DecodeString(leftHex)
	right, _ := hex.DecodeString(rightHex)

	combined := make([]byte, 0, len(left)+len(right))
	combined = append(combined, left...)
	combined = append(combined, right...)

	hash := sha256.Sum256(combined)
	return hex.EncodeToString(hash[:])
}

// --- Proof Generation ---

// GenerateProof creates a Merkle inclusion proof for a given leaf hash.
//
// The proof consists of sibling hashes from the leaf to the root.
// Together with the leaf hash, these siblings allow anyone to
// recompute the root and verify the leaf is included.
func (t *Tree) GenerateProof(leafHash string) (*models.MerkleProof, error) {
	idx, ok := t.leafIndex[leafHash]
	if !ok {
		return nil, fmt.Errorf("%w: %s", ErrLeafNotFound, leafHash)
	}

	siblings := make([]string, 0, t.Depth)
	currentIdx := idx

	for level := 0; level < t.Depth; level++ {
		levelNodes := t.Levels[level]

		// Determine sibling index
		var siblingIdx int
		if currentIdx%2 == 0 {
			// Current is left child, sibling is right
			siblingIdx = currentIdx + 1
			if siblingIdx >= len(levelNodes) {
				siblingIdx = currentIdx // Odd node count: sibling is self
			}
		} else {
			// Current is right child, sibling is left
			siblingIdx = currentIdx - 1
		}

		siblings = append(siblings, levelNodes[siblingIdx])

		// Move to parent index
		currentIdx = currentIdx / 2
	}

	return &models.MerkleProof{
		LeafHash:  leafHash,
		LeafIndex: idx,
		Siblings:  siblings,
		Root:      t.Root,
	}, nil
}

// --- Proof Verification ---

// VerifyProof checks that a Merkle proof is valid for a given leaf and root.
//
// This function is designed to be used by external auditors and the
// public verification portal. It takes only the proof data and the
// expected root — no access to the full tree is needed.
func VerifyProof(proof *models.MerkleProof, expectedRoot string) error {
	if proof == nil {
		return ErrInvalidProof
	}

	currentHash := proof.LeafHash
	currentIdx := proof.LeafIndex

	for _, sibling := range proof.Siblings {
		if currentIdx%2 == 0 {
			// Current is left child
			currentHash = hashPair(currentHash, sibling)
		} else {
			// Current is right child
			currentHash = hashPair(sibling, currentHash)
		}
		currentIdx = currentIdx / 2
	}

	if currentHash != expectedRoot {
		return fmt.Errorf("%w: computed %s, expected %s", ErrRootMismatch, currentHash, expectedRoot)
	}

	return nil
}

// --- Leaf Hash Computation ---

// ComputeLeafHash computes the SHA-256 hash of a VoteCast record for use
// as a Merkle tree leaf. The hash covers all critical fields.
//
// The canonical serialization order is fixed and must never change,
// as it would invalidate all existing proofs.
func ComputeLeafHash(vc *models.VoteCast) string {
	hasher := sha256.New()

	// Fixed serialization order — DO NOT CHANGE
	hasher.Write([]byte(vc.VoteRecordID))
	hasher.Write([]byte(vc.ElectionID))
	hasher.Write([]byte(vc.PrecinctID))
	hasher.Write(vc.VoterToken)
	hasher.Write([]byte(vc.VoterTokenHash))
	hasher.Write(vc.VoterTokenSignature)
	hasher.Write([]byte(vc.BiometricHash))
	hasher.Write([]byte(vc.MachineID))
	hasher.Write([]byte(vc.CastTimestamp.UTC().Format(time.RFC3339Nano)))
	hasher.Write([]byte(vc.Nonce))
	hasher.Write([]byte(string(vc.Status)))

	// Include each selection in deterministic order
	for _, sel := range vc.Selections {
		hasher.Write([]byte(sel.RaceID))
		hasher.Write([]byte(sel.SelectionHash))
		hasher.Write([]byte(fmt.Sprintf("%d", sel.RankPosition)))
	}

	return hex.EncodeToString(hasher.Sum(nil))
}

// --- Hierarchy ---

// BuildHierarchyRoot computes a Merkle root from a set of child roots
// (e.g., all precinct roots in a county, or all county roots in a state).
func BuildHierarchyRoot(childRoots []string) (string, error) {
	if len(childRoots) == 0 {
		return "", ErrEmptyLeaves
	}

	tree, err := BuildTree(childRoots[0], childRoots[1:])
	if err != nil {
		return "", fmt.Errorf("merkle: building hierarchy: %w", err)
	}

	return tree.Root, nil
}

// --- Export for Persistence ---

// AllNodes returns all nodes in the tree as a flat slice for database storage.
func (t *Tree) AllNodes() []models.MerkleNode {
	var nodes []models.MerkleNode

	for level, levelNodes := range t.Levels {
		for idx, hash := range levelNodes {
			node := models.MerkleNode{
				TreeLevel: level,
				NodeIndex: idx,
				NodeHash:  hash,
			}

			// For non-leaf nodes, record children
			if level > 0 {
				childLevel := t.Levels[level-1]
				leftIdx := idx * 2
				if leftIdx < len(childLevel) {
					node.LeftChildHash = childLevel[leftIdx]
				}
				rightIdx := leftIdx + 1
				if rightIdx < len(childLevel) {
					node.RightChildHash = childLevel[rightIdx]
				} else if leftIdx < len(childLevel) {
					node.RightChildHash = childLevel[leftIdx] // Odd padding
				}
			}

			nodes = append(nodes, node)
		}
	}

	return nodes
}

// --- Verification Utilities ---

// VerifyTreeIntegrity recomputes the entire tree from leaves and checks
// that the root matches. Used during post-election audits.
func VerifyTreeIntegrity(leaves []string, expectedRoot string) error {
	if len(leaves) == 0 {
		return ErrEmptyLeaves
	}

	// Recompute the tree
	tree, err := BuildTree(leaves[0], leaves[1:])
	if err != nil {
		return fmt.Errorf("merkle: recomputing tree: %w", err)
	}

	if tree.Root != expectedRoot {
		return fmt.Errorf("%w: recomputed %s, expected %s", ErrRootMismatch, tree.Root, expectedRoot)
	}

	return nil
}
