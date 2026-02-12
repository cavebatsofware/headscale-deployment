package build

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"oci-image-builder/internal/config"
)

// buildLocal builds an image locally using nix build.
func (b *Builder) buildLocal(ctx context.Context, image *config.ImageDef) (string, error) {
	outputLink := fmt.Sprintf("result-%s", image.Name)
	target := fmt.Sprintf(".#%s", image.FlakeTarget)

	b.Logger.Logf("Building %s locally...", image.Name)
	b.Logger.Logf("  Target: %s", target)
	b.Logger.Logf("  Output: %s", outputLink)

	cmd := exec.CommandContext(ctx, "nix", "build", target, "--out-link", outputLink)
	cmd.Dir = "."

	stderr, err := cmd.StderrPipe()
	if err != nil {
		return "", fmt.Errorf("failed to create stderr pipe: %w", err)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return "", fmt.Errorf("failed to create stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("failed to start nix build: %w", err)
	}

	// Stream stderr (nix outputs progress to stderr)
	go func() {
		scanner := bufio.NewScanner(stderr)
		for scanner.Scan() {
			b.Logger.Log(scanner.Text())
		}
	}()

	// Stream stdout
	go func() {
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			b.Logger.Log(scanner.Text())
		}
	}()

	if err := cmd.Wait(); err != nil {
		return "", fmt.Errorf("nix build failed: %w", err)
	}

	// Resolve symlink to get actual path
	qcowPath := filepath.Join(outputLink, "nixos.qcow2")
	resolved, err := filepath.EvalSymlinks(qcowPath)
	if err != nil {
		// Try without symlink resolution
		if _, statErr := os.Stat(qcowPath); statErr == nil {
			return qcowPath, nil
		}
		return "", fmt.Errorf("failed to resolve output path: %w", err)
	}

	return resolved, nil
}
