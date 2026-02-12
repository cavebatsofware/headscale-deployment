// Package build handles building NixOS images locally and remotely.
package build

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"oci-image-builder/internal/config"
	"oci-image-builder/internal/logger"
)

// BuildResult contains the result of a build operation.
type BuildResult struct {
	ImageName  string
	OutputPath string
	SizeBytes  int64
	Error      error
}

// Builder handles building NixOS images.
type Builder struct {
	Config    *config.Config
	LocalOnly bool
	Logger    *logger.Logger
}

// NewBuilder creates a new Builder instance.
func NewBuilder(cfg *config.Config, localOnly bool) *Builder {
	return &Builder{
		Config:    cfg,
		LocalOnly: localOnly,
		Logger:    logger.New(),
	}
}

// SetLogFunc sets the logging function for progress output.
func (b *Builder) SetLogFunc(fn func(string)) {
	b.Logger.SetLogFunc(fn)
}

// CheckPrerequisites verifies that required tools are available.
func CheckPrerequisites(needSSH bool) error {
	if _, err := exec.LookPath("nix"); err != nil {
		return fmt.Errorf("nix not found in PATH. Install Nix from https://nixos.org/download")
	}

	if needSSH {
		if _, err := exec.LookPath("ssh"); err != nil {
			return fmt.Errorf("ssh not found in PATH")
		}
		if _, err := exec.LookPath("rsync"); err != nil {
			return fmt.Errorf("rsync not found in PATH")
		}
		if _, err := exec.LookPath("scp"); err != nil {
			return fmt.Errorf("scp not found in PATH")
		}
	}

	return nil
}

// Build builds the specified images.
func (b *Builder) Build(ctx context.Context, imageNames []string) (map[string]BuildResult, error) {
	results := make(map[string]BuildResult)

	for _, name := range imageNames {
		imageDef := b.Config.GetImage(name)
		if imageDef == nil {
			return nil, fmt.Errorf("unknown image: %s", name)
		}

		var result BuildResult
		result.ImageName = name

		// Choose build method based on architecture and LocalOnly flag
		if imageDef.Arch == config.ArchAarch64 && !b.LocalOnly {
			if b.Config.ARM64Builder != nil && b.Config.ARM64Builder.IsMacOS {
				result.OutputPath, result.Error = b.buildRemoteMacOS(ctx, imageDef)
			} else {
				result.OutputPath, result.Error = b.buildRemote(ctx, imageDef)
			}
		} else {
			result.OutputPath, result.Error = b.buildLocal(ctx, imageDef)
		}

		if result.Error != nil {
			return nil, result.Error
		}

		// Get file size
		if info, err := os.Stat(result.OutputPath); err == nil {
			result.SizeBytes = info.Size()
		}

		b.Logger.Logf("Build complete: %s (%d MB)", result.OutputPath, result.SizeBytes/(1024*1024))
		results[name] = result
	}

	return results, nil
}

// NeedsRemoteBuild returns true if any of the images require remote building.
func (b *Builder) NeedsRemoteBuild(imageNames []string) bool {
	if b.LocalOnly {
		return false
	}

	for _, name := range imageNames {
		imageDef := b.Config.GetImage(name)
		if imageDef != nil && imageDef.Arch == config.ArchAarch64 {
			return true
		}
	}
	return false
}

// expandPath expands ~ in paths.
func expandPath(path string) string {
	if len(path) > 0 && path[0] == '~' {
		home, err := os.UserHomeDir()
		if err != nil {
			return path
		}
		return filepath.Join(home, path[1:])
	}
	return path
}
