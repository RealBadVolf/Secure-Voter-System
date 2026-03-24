package merkle

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math/rand"
	"testing"
)

// ==========================================================================
// UNIT TESTS
// ==========================================================================

func TestBuildTree_SingleLeaf(t *testing.T) {
	tree, err := BuildTree("genesis", []string{"leaf1"})
	if err != nil {
		t.Fatalf("BuildTree failed: %v", err)
	}
	if tree.LeafCount != 2 {
		t.Errorf("LeafCount = %d, want 2", tree.LeafCount)
	}
	if tree.Root == "" {
		t.Fatal("Root is empty")
	}
}

func TestBuildTree_EmptyLeaves(t *testing.T) {
	_, err := BuildTree("genesis", []string{})
	if err != ErrEmptyLeaves {
		t.Errorf("Expected ErrEmptyLeaves, got: %v", err)
	}
}

func TestBuildTree_OddLeafCount(t *testing.T) {
	tree, err := BuildTree("genesis", []string{"a", "b"})
	if err != nil {
		t.Fatalf("BuildTree failed: %v", err)
	}
	if tree.Root == "" {
		t.Fatal("Root is empty")
	}
}

func TestBuildTree_LargeTree(t *testing.T) {
	leaves := make([]string, 10000)
	for i := range leaves {
		h := sha256.Sum256([]byte(fmt.Sprintf("vote-%d", i)))
		leaves[i] = hex.EncodeToString(h[:])
	}
	tree, err := BuildTree("genesis-hash", leaves)
	if err != nil {
		t.Fatalf("BuildTree failed: %v", err)
	}
	t.Logf("10,000 leaves: depth=%d, root=%s..., built in %dms",
		tree.Depth, tree.Root[:16], tree.BuildTimeMs)
}

func TestProofGeneration_AllLeaves(t *testing.T) {
	leaves := make([]string, 8)
	for i := range leaves {
		h := sha256.Sum256([]byte(fmt.Sprintf("vote-%d", i)))
		leaves[i] = hex.EncodeToString(h[:])
	}
	tree, err := BuildTree("genesis", leaves)
	if err != nil {
		t.Fatalf("BuildTree failed: %v", err)
	}

	allLeaves := append([]string{"genesis"}, leaves...)
	for _, leaf := range allLeaves {
		proof, err := tree.GenerateProof(leaf)
		if err != nil {
			t.Fatalf("GenerateProof(%s...) failed: %v", leaf[:8], err)
		}
		if err := VerifyProof(proof, tree.Root); err != nil {
			t.Fatalf("VerifyProof(%s...) failed: %v", leaf[:8], err)
		}
	}
}

func TestProofGeneration_NonExistentLeaf(t *testing.T) {
	tree, _ := BuildTree("genesis", []string{"a", "b"})
	_, err := tree.GenerateProof("nonexistent")
	if err == nil {
		t.Fatal("Expected error for nonexistent leaf")
	}
}

func TestVerifyProof_WrongRoot(t *testing.T) {
	tree, _ := BuildTree("genesis", []string{"a", "b", "c"})
	proof, _ := tree.GenerateProof("a")
	err := VerifyProof(proof, "wrong-root-hash")
	if err == nil {
		t.Fatal("Expected error for wrong root")
	}
}

func TestVerifyProof_NilProof(t *testing.T) {
	err := VerifyProof(nil, "some-root")
	if err != ErrInvalidProof {
		t.Errorf("Expected ErrInvalidProof, got: %v", err)
	}
}

func TestVerifyTreeIntegrity_ValidTree(t *testing.T) {
	leaves := []string{"a", "b", "c", "d"}
	tree, _ := BuildTree(leaves[0], leaves[1:])
	err := VerifyTreeIntegrity(leaves, tree.Root)
	if err != nil {
		t.Fatalf("VerifyTreeIntegrity failed: %v", err)
	}
}

func TestVerifyTreeIntegrity_TamperedLeaf(t *testing.T) {
	leaves := []string{"a", "b", "c", "d"}
	tree, _ := BuildTree(leaves[0], leaves[1:])
	tamperedLeaves := []string{"a", "b", "TAMPERED", "d"}
	err := VerifyTreeIntegrity(tamperedLeaves, tree.Root)
	if err == nil {
		t.Fatal("Expected error for tampered leaf")
	}
}

func TestAllNodes_ContainsRoot(t *testing.T) {
	tree, _ := BuildTree("g", []string{"a", "b", "c"})
	nodes := tree.AllNodes()
	foundRoot := false
	for _, n := range nodes {
		if n.NodeHash == tree.Root {
			foundRoot = true
		}
	}
	if !foundRoot {
		t.Error("Root hash not found in AllNodes output")
	}
}

func TestHierarchyRoot(t *testing.T) {
	precinctRoots := []string{"root-precinct-1", "root-precinct-2", "root-precinct-3"}
	countyRoot, err := BuildHierarchyRoot(precinctRoots)
	if err != nil {
		t.Fatalf("BuildHierarchyRoot failed: %v", err)
	}
	if countyRoot == "" {
		t.Fatal("County root is empty")
	}

	// Deterministic: same inputs → same root
	countyRoot2, _ := BuildHierarchyRoot(precinctRoots)
	if countyRoot != countyRoot2 {
		t.Fatal("Hierarchy root is not deterministic")
	}
}

// ==========================================================================
// PROPERTY-BASED TESTS
// ==========================================================================

func TestProperty_RootIsDeterministic(t *testing.T) {
	rng := rand.New(rand.NewSource(42))
	for trial := 0; trial < 100; trial++ {
		n := rng.Intn(50) + 1
		leaves := makeLeaves(n, fmt.Sprintf("det-t%d", trial))
		genesis := fmt.Sprintf("genesis-%d", trial)

		tree1, _ := BuildTree(genesis, leaves)
		tree2, _ := BuildTree(genesis, leaves)

		if tree1.Root != tree2.Root {
			t.Fatalf("PROPERTY VIOLATION: determinism failed at trial %d (n=%d)", trial, n)
		}
	}
}

func TestProperty_AllLeavesHaveValidProofs(t *testing.T) {
	rng := rand.New(rand.NewSource(99))
	for trial := 0; trial < 50; trial++ {
		n := rng.Intn(100) + 2
		leaves := makeLeaves(n, fmt.Sprintf("proof-t%d", trial))
		genesis := fmt.Sprintf("g-%d", trial)
		tree, _ := BuildTree(genesis, leaves)

		allLeaves := append([]string{genesis}, leaves...)
		for _, leaf := range allLeaves {
			proof, err := tree.GenerateProof(leaf)
			if err != nil {
				t.Fatalf("Trial %d: GenerateProof failed: %v", trial, err)
			}
			if err := VerifyProof(proof, tree.Root); err != nil {
				t.Fatalf("Trial %d: VerifyProof failed: %v", trial, err)
			}
		}
	}
}

func TestProperty_DifferentInputsDifferentRoots(t *testing.T) {
	genesis := "collision-test"
	roots := make(map[string]bool)
	for i := 0; i < 1000; i++ {
		h := sha256.Sum256([]byte(fmt.Sprintf("unique-vote-%d", i)))
		leaves := []string{hex.EncodeToString(h[:])}
		tree, _ := BuildTree(genesis, leaves)
		if roots[tree.Root] {
			t.Fatalf("COLLISION at iteration %d", i)
		}
		roots[tree.Root] = true
	}
}

func TestProperty_SingleLeafChangeMutatesRoot(t *testing.T) {
	rng := rand.New(rand.NewSource(77))
	for trial := 0; trial < 50; trial++ {
		n := rng.Intn(20) + 3
		leaves := makeLeaves(n, fmt.Sprintf("mutate-t%d", trial))
		tree, _ := BuildTree("genesis", leaves)

		for changeIdx := 0; changeIdx < n; changeIdx++ {
			modified := make([]string, n)
			copy(modified, leaves)
			h := sha256.Sum256([]byte(fmt.Sprintf("mutate-t%d-v%d-CHANGED", trial, changeIdx)))
			modified[changeIdx] = hex.EncodeToString(h[:])

			modTree, _ := BuildTree("genesis", modified)
			if modTree.Root == tree.Root {
				t.Fatalf("Changing leaf %d did not change root (trial %d)", changeIdx, trial)
			}
		}
	}
}

// ==========================================================================
// BENCHMARKS
// ==========================================================================

func BenchmarkBuildTree_100(b *testing.B)    { benchBuild(b, 100) }
func BenchmarkBuildTree_1000(b *testing.B)   { benchBuild(b, 1000) }
func BenchmarkBuildTree_5000(b *testing.B)   { benchBuild(b, 5000) }
func BenchmarkBuildTree_10000(b *testing.B)  { benchBuild(b, 10000) }
func BenchmarkBuildTree_50000(b *testing.B)  { benchBuild(b, 50000) }
func BenchmarkBuildTree_100000(b *testing.B) { benchBuild(b, 100000) }

func benchBuild(b *testing.B, n int) {
	leaves := makeLeaves(n, "bench")
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		BuildTree("genesis", leaves)
	}
}

func BenchmarkGenerateProof_5000(b *testing.B) {
	leaves := makeLeaves(5000, "bench-proof")
	tree, _ := BuildTree("genesis", leaves)
	target := leaves[2500]
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		tree.GenerateProof(target)
	}
}

func BenchmarkVerifyProof_5000(b *testing.B) {
	leaves := makeLeaves(5000, "bench-verify")
	tree, _ := BuildTree("genesis", leaves)
	proof, _ := tree.GenerateProof(leaves[2500])
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		VerifyProof(proof, tree.Root)
	}
}

// ==========================================================================
// FUZZ TESTS
// ==========================================================================

func FuzzBuildTree(f *testing.F) {
	f.Add(1, "seed")
	f.Add(5, "another")
	f.Add(100, "lots")

	f.Fuzz(func(t *testing.T, n int, seed string) {
		if n < 1 || n > 10000 {
			return
		}
		leaves := makeLeaves(n, seed)
		tree, err := BuildTree("fuzz-genesis", leaves)
		if err != nil {
			t.Fatalf("BuildTree failed: %v", err)
		}
		if tree.Root == "" {
			t.Fatal("Root is empty")
		}
		if tree.LeafCount != n+1 {
			t.Fatalf("LeafCount = %d, want %d", tree.LeafCount, n+1)
		}
	})
}

func FuzzVerifyProof(f *testing.F) {
	f.Add(3, 0)
	f.Add(10, 5)
	f.Add(50, 25)

	f.Fuzz(func(t *testing.T, n int, idx int) {
		if n < 2 || n > 1000 {
			return
		}
		if idx < 0 {
			idx = -idx
		}
		idx = idx % n

		leaves := makeLeaves(n, "fuzz-vp")
		tree, _ := BuildTree("fuzz-g", leaves)
		proof, err := tree.GenerateProof(leaves[idx])
		if err != nil {
			t.Fatalf("GenerateProof: %v", err)
		}
		if err := VerifyProof(proof, tree.Root); err != nil {
			t.Fatalf("VerifyProof: %v", err)
		}
	})
}

// ==========================================================================
// HELPERS
// ==========================================================================

func makeLeaves(n int, prefix string) []string {
	leaves := make([]string, n)
	for i := range leaves {
		h := sha256.Sum256([]byte(fmt.Sprintf("%s-%d", prefix, i)))
		leaves[i] = hex.EncodeToString(h[:])
	}
	return leaves
}
