// Package config handles TOML configuration loading for oci-image-builder.
// Configuration format is compatible with the previous Rust implementation.
package config

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/pelletier/go-toml/v2"
)

// Arch represents the target architecture for an image.
type Arch string

const (
	ArchX86_64  Arch = "x86_64"
	ArchAarch64 Arch = "aarch64"
)

// Config is the root configuration structure.
type Config struct {
	OCI          OCIConfig       `toml:"oci"`
	ARM64Builder *ARM64Builder   `toml:"arm64_builder"`
	Images       []ImageDef      `toml:"images"`
}

// OCIConfig contains OCI-specific configuration.
type OCIConfig struct {
	CompartmentOCID  string `toml:"compartment_ocid"`
	BucketName       string `toml:"bucket_name"`
	Region           string `toml:"region"`
	Profile          string `toml:"profile"`
	Auth             string `toml:"auth"` // "api_key" or "security_token"
	PollIntervalSecs int    `toml:"poll_interval_secs"`
	MaxWaitSecs      int    `toml:"max_wait_secs"`
	InitialDelaySecs int    `toml:"initial_delay_secs"`
}

// ARM64Builder contains configuration for remote ARM64 builds.
type ARM64Builder struct {
	Host     string `toml:"host"`
	User     string `toml:"user"`
	SSHKey   string `toml:"ssh_key"`
	RepoPath string `toml:"repo_path"`
	IsMacOS  bool   `toml:"is_macos"`

	// Linux-builder VM settings (for macOS hosts)
	VMPort    int    `toml:"vm_port"`     // SSH port for linux-builder VM (default: 31022)
	VMUser    string `toml:"vm_user"`     // User for linux-builder VM (default: builder)
	VMKeyPath string `toml:"vm_key_path"` // Path to VM SSH key on Mac (default: /etc/nix/builder_ed25519)
}

// GetVMPort returns the VM SSH port, defaulting to 31022.
func (b *ARM64Builder) GetVMPort() int {
	if b.VMPort == 0 {
		return 31022
	}
	return b.VMPort
}

// GetVMUser returns the VM user, defaulting to "builder".
func (b *ARM64Builder) GetVMUser() string {
	if b.VMUser == "" {
		return "builder"
	}
	return b.VMUser
}

// GetVMKeyPath returns the VM key path, defaulting to "/etc/nix/builder_ed25519".
func (b *ARM64Builder) GetVMKeyPath() string {
	if b.VMKeyPath == "" {
		return "/etc/nix/builder_ed25519"
	}
	return b.VMKeyPath
}

// ImageDef defines a single image to build.
type ImageDef struct {
	Name         string `toml:"name"`
	FlakeTarget  string `toml:"flake_target"`
	Arch         Arch   `toml:"arch"`
	TerraformVar string `toml:"terraform_var"`
}

// DefaultConfig returns a config with default values.
func DefaultConfig() *Config {
	return &Config{
		OCI: OCIConfig{
			PollIntervalSecs: 30,
			MaxWaitSecs:      1800,
			InitialDelaySecs: 30,
			Auth:             "api_key",
		},
		Images: []ImageDef{
			{Name: "headscale", FlakeTarget: "oci-headscale-image", Arch: ArchX86_64, TerraformVar: "headscale_image_ocid"},
			{Name: "keycloak", FlakeTarget: "oci-keycloak-image", Arch: ArchAarch64, TerraformVar: "keycloak_image_ocid"},
			{Name: "derp", FlakeTarget: "oci-derp-east-image", Arch: ArchAarch64, TerraformVar: "derp_image_ocid"},
		},
	}
}

// Load loads configuration from the given path, or searches default locations.
func Load(path string) (*Config, error) {
	var configPath string

	if path != "" {
		configPath = path
	} else {
		// Search default locations
		locations := []string{
			"oci-image-builder.toml",
			"scripts/oci-image-builder.toml",
		}

		// Add XDG config path
		if home, err := os.UserHomeDir(); err == nil {
			locations = append(locations, filepath.Join(home, ".config", "oci-image-builder", "config.toml"))
		}

		for _, loc := range locations {
			if _, err := os.Stat(loc); err == nil {
				configPath = loc
				break
			}
		}

		if configPath == "" {
			return nil, fmt.Errorf("config file not found. Run 'oci-image-builder init' to create one")
		}
	}

	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read config file %s: %w", configPath, err)
	}

	cfg := DefaultConfig()
	if err := toml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("failed to parse config file: %w", err)
	}

	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	return cfg, nil
}

// Validate checks the configuration for required fields and consistency.
func (c *Config) Validate() error {
	if c.OCI.CompartmentOCID == "" {
		return fmt.Errorf("oci.compartment_ocid is required")
	}
	if c.OCI.BucketName == "" {
		return fmt.Errorf("oci.bucket_name is required")
	}
	if c.OCI.Region == "" {
		return fmt.Errorf("oci.region is required")
	}

	// Check if ARM64 builder is needed but not configured
	hasARM64 := false
	for _, img := range c.Images {
		if img.Arch == ArchAarch64 {
			hasARM64 = true
			break
		}
	}
	if hasARM64 && c.ARM64Builder == nil {
		// Just warn, don't error - user might use --local-only
		fmt.Fprintln(os.Stderr, "Warning: ARM64 images defined but arm64_builder not configured. Use --local-only for local builds.")
	}

	return nil
}

// GetImage returns the image definition by name, or nil if not found.
func (c *Config) GetImage(name string) *ImageDef {
	for i := range c.Images {
		if c.Images[i].Name == name {
			return &c.Images[i]
		}
	}
	return nil
}

// GetAllImageNames returns a slice of all image names.
func (c *Config) GetAllImageNames() []string {
	names := make([]string, len(c.Images))
	for i, img := range c.Images {
		names[i] = img.Name
	}
	return names
}

// DefaultConfigTemplate returns the template for a new config file.
func DefaultConfigTemplate() string {
	return `# OCI Image Builder Configuration

[oci]
# Required: Your OCI compartment OCID
compartment_ocid = "ocid1.compartment.oc1..example"

# Object Storage bucket for image uploads
bucket_name = "nixos-images"

# OCI region (e.g., us-ashburn-1, us-phoenix-1)
region = "us-ashburn-1"

# Optional: OCI CLI profile name from ~/.oci/config
# profile = "DEFAULT"

# Authentication type: "api_key" (default) or "security_token"
# auth = "api_key"

# Polling settings for import status
poll_interval_secs = 30
max_wait_secs = 1800
initial_delay_secs = 30

# ARM64 remote builder (required for aarch64 images unless using --local-only)
# [arm64_builder]
# host = "192.168.1.100"
# user = "builder"
# ssh_key = "~/.ssh/id_ed25519"
# repo_path = "~/headscale-deployment"
# is_macos = false

# Image definitions
[[images]]
name = "headscale"
flake_target = "oci-headscale-image"
arch = "x86_64"
terraform_var = "headscale_image_ocid"

[[images]]
name = "keycloak"
flake_target = "oci-keycloak-image"
arch = "aarch64"
terraform_var = "keycloak_image_ocid"

[[images]]
name = "derp"
flake_target = "oci-derp-east-image"
arch = "aarch64"
terraform_var = "derp_image_ocid"
`
}

// InitConfigFile creates a default config file at the standard location.
func InitConfigFile() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("failed to get home directory: %w", err)
	}

	configDir := filepath.Join(home, ".config", "oci-image-builder")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return "", fmt.Errorf("failed to create config directory: %w", err)
	}

	configPath := filepath.Join(configDir, "config.toml")

	// Don't overwrite existing config
	if _, err := os.Stat(configPath); err == nil {
		return configPath, fmt.Errorf("config file already exists at %s", configPath)
	}

	if err := os.WriteFile(configPath, []byte(DefaultConfigTemplate()), 0644); err != nil {
		return "", fmt.Errorf("failed to write config file: %w", err)
	}

	return configPath, nil
}
