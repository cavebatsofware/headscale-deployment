package build

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"oci-image-builder/internal/config"
)

// buildRemoteMacOS builds an image on a macOS ARM64 builder via its linux-builder VM.
// This is a multi-hop process:
// 1. Sync files to Mac host
// 2. Copy files into linux-builder VM
// 3. Build inside VM
// 4. Copy result from VM to Mac host
// 5. Copy result from Mac host to local machine
func (b *Builder) buildRemoteMacOS(ctx context.Context, image *config.ImageDef) (string, error) {
	builder := b.Config.ARM64Builder
	if builder == nil {
		return "", fmt.Errorf("ARM64 builder not configured")
	}

	sshTarget := fmt.Sprintf("%s@%s", builder.User, builder.Host)
	outputLink := fmt.Sprintf("result-%s", image.Name)
	localOutput := filepath.Join(outputLink, "nixos.qcow2")

	// Get VM settings with defaults
	vmPort := builder.GetVMPort()
	vmUser := builder.GetVMUser()
	vmKeyPath := builder.GetVMKeyPath()

	b.Logger.Logf("Building %s on macOS builder %s (via linux-builder VM)...", image.Name, builder.Host)

	// Step 0: Clean up old builds to free disk space
	b.Logger.Log("Cleaning up old builds...")
	macCleanupCmd := fmt.Sprintf("rm -f %s/result-*-nixos.qcow2 2>/dev/null || true", builder.RepoPath)
	if err := runSSHCommand(ctx, b.Logger, sshTarget, macCleanupCmd); err != nil {
		b.Logger.Logf("  Mac cleanup warning (non-fatal): %v", err)
	}

	vmCleanupCmd := fmt.Sprintf(
		"ssh -o StrictHostKeyChecking=no -i %s -p %d %s@localhost "+
			"'rm -rf ~/build-* 2>/dev/null; nix-collect-garbage -d 2>/dev/null || true'",
		vmKeyPath, vmPort, vmUser,
	)
	if err := runSSHCommand(ctx, b.Logger, sshTarget, vmCleanupCmd); err != nil {
		b.Logger.Logf("  VM cleanup warning (non-fatal): %v", err)
	}

	// Step 1: Sync nix files to Mac host
	b.Logger.Log("Syncing files to Mac host...")
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
		return "", fmt.Errorf("rsync to Mac host failed: %w", err)
	}

	// Step 2: Copy files from Mac host into linux-builder VM
	b.Logger.Log("Copying files into linux-builder VM...")
	copyToVMCmd := fmt.Sprintf(
		"ssh -o StrictHostKeyChecking=no -i %s -p %d %s@localhost 'mkdir -p ~/build-%s' && "+
			"scp -o StrictHostKeyChecking=no -i %s -P %d -r %s/{flake.nix,flake.lock,nix} %s@localhost:~/build-%s/",
		vmKeyPath, vmPort, vmUser, image.Name,
		vmKeyPath, vmPort, builder.RepoPath, vmUser, image.Name,
	)

	if err := runSSHCommand(ctx, b.Logger, sshTarget, copyToVMCmd); err != nil {
		return "", fmt.Errorf("failed to copy files into linux-builder VM: %w", err)
	}

	// Step 3: Build inside the linux-builder VM
	b.Logger.Log("Running nix build inside linux-builder VM...")
	innerCmd := fmt.Sprintf(
		"cd ~/build-%s && nix build '.#%s' --out-link result-%s --max-jobs auto --extra-experimental-features nix-command --extra-experimental-features flakes",
		image.Name, image.FlakeTarget, image.Name,
	)
	buildInVMCmd := fmt.Sprintf(
		"ssh -o StrictHostKeyChecking=no -i %s -p %d %s@localhost '%s'",
		vmKeyPath, vmPort, vmUser, innerCmd,
	)

	if err := runSSHCommand(ctx, b.Logger, sshTarget, buildInVMCmd); err != nil {
		return "", fmt.Errorf("nix build in linux-builder VM failed: %w", err)
	}

	// Step 4: Copy result from VM to Mac host
	b.Logger.Log("Copying image from linux-builder VM to Mac host...")
	copyFromVMCmd := fmt.Sprintf(
		"scp -o StrictHostKeyChecking=no -i %s -P %d %s@localhost:~/build-%s/result-%s/nixos.qcow2 %s/result-%s-nixos.qcow2",
		vmKeyPath, vmPort, vmUser, image.Name, image.Name, builder.RepoPath, image.Name,
	)

	if err := runSSHCommand(ctx, b.Logger, sshTarget, copyFromVMCmd); err != nil {
		return "", fmt.Errorf("failed to copy image from linux-builder VM: %w", err)
	}

	// Step 5: Copy result from Mac host to local machine
	b.Logger.Log("Copying image from Mac host to local machine...")
	if err := os.MkdirAll(outputLink, 0755); err != nil {
		return "", fmt.Errorf("failed to create output directory: %w", err)
	}

	scpSrc := fmt.Sprintf("%s:%s/result-%s-nixos.qcow2", sshTarget, builder.RepoPath, image.Name)
	if err := runCommand(ctx, b.Logger, "scp", "-o", "BatchMode=yes", scpSrc, localOutput); err != nil {
		return "", fmt.Errorf("scp from Mac host failed: %w", err)
	}

	resolved, err := filepath.Abs(localOutput)
	if err != nil {
		return localOutput, nil
	}

	b.Logger.Logf("Build complete: %s", resolved)
	return resolved, nil
}
