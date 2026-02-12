package build

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"oci-image-builder/internal/config"
	"oci-image-builder/internal/logger"
)

// buildRemote builds an image on a remote Linux ARM64 builder via SSH.
func (b *Builder) buildRemote(ctx context.Context, image *config.ImageDef) (string, error) {
	builder := b.Config.ARM64Builder
	if builder == nil {
		return "", fmt.Errorf("ARM64 builder not configured")
	}

	sshTarget := fmt.Sprintf("%s@%s", builder.User, builder.Host)
	outputLink := fmt.Sprintf("result-%s", image.Name)
	localOutput := filepath.Join(outputLink, "nixos.qcow2")

	b.Logger.Logf("Building %s on remote builder %s...", image.Name, builder.Host)

	// Step 0: Clean up old builds to free disk space
	b.Logger.Log("Cleaning up old builds on remote builder...")
	cleanupCmd := fmt.Sprintf(
		"cd %s && rm -f result-* 2>/dev/null; nix-collect-garbage -d 2>/dev/null || true",
		builder.RepoPath,
	)
	if err := runSSHCommand(ctx, b.Logger, sshTarget, cleanupCmd); err != nil {
		b.Logger.Logf("  Cleanup warning (non-fatal): %v", err)
	}

	// Step 1: Sync nix files to remote builder
	b.Logger.Log("Syncing files to remote builder...")
	rsyncArgs := []string{
		"-az", "--delete", "-v",
		"-e", "ssh -o BatchMode=yes",
		"--include=flake.nix",
		"--include=flake.lock",
		"--include=nix/***",
		"--exclude=*",
		"./",
		fmt.Sprintf("%s:%s/", sshTarget, builder.RepoPath),
	}

	if err := runCommand(ctx, b.Logger, "rsync", rsyncArgs...); err != nil {
		return "", fmt.Errorf("rsync to remote builder failed: %w", err)
	}

	// Step 2: Run nix build on remote
	b.Logger.Log("Running nix build on remote builder...")
	buildCmd := fmt.Sprintf("cd %s && nix build '.#%s' --out-link result-%s",
		builder.RepoPath, image.FlakeTarget, image.Name)

	if err := runSSHCommand(ctx, b.Logger, sshTarget, buildCmd); err != nil {
		return "", fmt.Errorf("remote nix build failed: %w", err)
	}

	// Step 3: Copy result back
	b.Logger.Log("Copying build result from remote builder...")
	if err := os.MkdirAll(outputLink, 0755); err != nil {
		return "", fmt.Errorf("failed to create output directory: %w", err)
	}

	scpSrc := fmt.Sprintf("%s:%s/result-%s/nixos.qcow2", sshTarget, builder.RepoPath, image.Name)
	if err := runCommand(ctx, b.Logger, "scp", "-o", "BatchMode=yes", scpSrc, localOutput); err != nil {
		return "", fmt.Errorf("scp failed to copy image: %w", err)
	}

	resolved, err := filepath.Abs(localOutput)
	if err != nil {
		return localOutput, nil
	}

	b.Logger.Logf("Build complete: %s", resolved)
	return resolved, nil
}

// runCommand runs a command and streams its output to the logger.
func runCommand(ctx context.Context, log *logger.Logger, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = os.Environ()

	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("failed to create stderr pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return err
	}

	go func() {
		scanner := bufio.NewScanner(stderr)
		for scanner.Scan() {
			log.Log(scanner.Text())
		}
	}()

	return cmd.Wait()
}

// runSSHCommand runs a command over SSH and streams its output.
func runSSHCommand(ctx context.Context, log *logger.Logger, target, command string) error {
	cmd := exec.CommandContext(ctx, "ssh", "-o", "BatchMode=yes", target, command)
	cmd.Env = os.Environ()

	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("failed to create stderr pipe: %w", err)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("failed to create stdout pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return err
	}

	go func() {
		scanner := bufio.NewScanner(stderr)
		for scanner.Scan() {
			log.Log(scanner.Text())
		}
	}()

	go func() {
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			log.Log(scanner.Text())
		}
	}()

	return cmd.Wait()
}
