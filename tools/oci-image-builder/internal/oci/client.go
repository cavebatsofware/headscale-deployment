// Package oci provides OCI SDK client operations for Object Storage and Compute.
package oci

import (
	"bufio"
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/oracle/oci-go-sdk/v65/common"
	"github.com/oracle/oci-go-sdk/v65/core"
	"github.com/oracle/oci-go-sdk/v65/objectstorage"
	"golang.org/x/term"

	"oci-image-builder/internal/config"
	"oci-image-builder/internal/logger"
)

// Constants for upload configuration
const (
	UploadPartSize   = 64 * 1024 * 1024 // 64 MB parts
	MaxRetryAttempts = 5
	RetryBackoffSecs = 10
)

// Client wraps OCI SDK clients for Object Storage and Compute operations.
type Client struct {
	ObjectStorage objectstorage.ObjectStorageClient
	Compute       core.ComputeClient
	Config        *config.Config
	Namespace     string
	Logger        *logger.Logger
}

// NewClient creates a new OCI client with the given configuration.
func NewClient(cfg *config.Config) (*Client, error) {
	provider, err := getConfigProvider(cfg, "")
	if err != nil {
		return nil, fmt.Errorf("failed to create OCI config provider: %w", err)
	}

	// Try to create clients - this may fail if key is encrypted
	objClient, computeClient, err := createClients(provider)
	if err != nil {
		// Check if it's an encrypted key error
		if isEncryptedKeyError(err) {
			profile := cfg.OCI.Profile
			if profile == "" {
				profile = "DEFAULT"
			}

			// Prompt for passphrase
			passphrase, promptErr := promptForPassphrase(profile)
			if promptErr != nil {
				return nil, fmt.Errorf("failed to read passphrase: %w", promptErr)
			}

			// Retry with passphrase
			provider, err = getConfigProvider(cfg, passphrase)
			if err != nil {
				return nil, fmt.Errorf("failed to create config provider with passphrase: %w", err)
			}

			objClient, computeClient, err = createClients(provider)
			if err != nil {
				return nil, fmt.Errorf("failed to create clients with passphrase: %w", err)
			}
		} else {
			return nil, fmt.Errorf("failed to create OCI clients: %w", err)
		}
	}

	// Set retry policies for long-running operations
	retryPolicy := newRetryPolicy()
	objClient.SetCustomClientConfiguration(common.CustomClientConfiguration{
		RetryPolicy: &retryPolicy,
	})
	computeClient.SetCustomClientConfiguration(common.CustomClientConfiguration{
		RetryPolicy: &retryPolicy,
	})

	// Remove timeout on ObjectStorage client for large file uploads
	// The default 60s timeout is too short for uploading large parts (64MB each)
	objClient.HTTPClient = &http.Client{}

	return &Client{
		ObjectStorage: objClient,
		Compute:       computeClient,
		Config:        cfg,
		Logger:        logger.New(),
	}, nil
}

// createClients creates the OCI SDK clients from a provider.
func createClients(provider common.ConfigurationProvider) (objectstorage.ObjectStorageClient, core.ComputeClient, error) {
	objClient, err := objectstorage.NewObjectStorageClientWithConfigurationProvider(provider)
	if err != nil {
		return objectstorage.ObjectStorageClient{}, core.ComputeClient{}, err
	}

	computeClient, err := core.NewComputeClientWithConfigurationProvider(provider)
	if err != nil {
		return objectstorage.ObjectStorageClient{}, core.ComputeClient{}, err
	}

	return objClient, computeClient, nil
}

// SetLogFunc sets the logging function for progress output.
func (c *Client) SetLogFunc(fn func(string)) {
	c.Logger.SetLogFunc(fn)
}

// GetNamespace retrieves and caches the Object Storage namespace.
func (c *Client) GetNamespace(ctx context.Context) (string, error) {
	if c.Namespace != "" {
		return c.Namespace, nil
	}

	req := objectstorage.GetNamespaceRequest{}
	resp, err := c.ObjectStorage.GetNamespace(ctx, req)
	if err != nil {
		return "", fmt.Errorf("failed to get namespace: %w", err)
	}

	c.Namespace = *resp.Value
	return c.Namespace, nil
}

// getConfigProvider creates the appropriate OCI configuration provider.
// If passphrase is provided, it will use that for decrypting the key.
func getConfigProvider(cfg *config.Config, passphrase string) (common.ConfigurationProvider, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("failed to get home directory: %w", err)
	}
	ociConfigPath := filepath.Join(home, ".oci", "config")

	if _, err := os.Stat(ociConfigPath); os.IsNotExist(err) {
		return nil, fmt.Errorf("OCI config not found at %s. Run 'oci setup config' to configure", ociConfigPath)
	}

	profile := cfg.OCI.Profile
	if profile == "" {
		profile = "DEFAULT"
	}

	if passphrase != "" {
		return common.ConfigurationProviderFromFileWithProfile(ociConfigPath, profile, passphrase)
	}

	return common.CustomProfileConfigProvider(ociConfigPath, profile), nil
}

// isEncryptedKeyError checks if the error indicates an encrypted key needs a password.
func isEncryptedKeyError(err error) bool {
	if err == nil {
		return false
	}
	errStr := err.Error()
	return strings.Contains(errStr, "private key password is required") ||
		strings.Contains(errStr, "failed to parse private key") ||
		strings.Contains(errStr, "decryption password") ||
		strings.Contains(errStr, "incorrect password") ||
		strings.Contains(errStr, "encrypted") ||
		strings.Contains(errStr, "ENCRYPTED") ||
		strings.Contains(errStr, "did not find a proper configuration for private key") ||
		strings.Contains(errStr, "could not parse private key")
}

// promptForPassphrase prompts the user to enter a passphrase for the OCI API key.
func promptForPassphrase(profile string) (string, error) {
	fmt.Printf("Enter passphrase for OCI API key (profile: %s): ", profile)

	passBytes, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Println()

	if err != nil {
		// Fallback to regular input if term.ReadPassword fails
		fmt.Printf("Enter passphrase for OCI API key (profile: %s): ", profile)
		reader := bufio.NewReader(os.Stdin)
		pass, readErr := reader.ReadString('\n')
		if readErr != nil {
			return "", fmt.Errorf("failed to read passphrase: %w", readErr)
		}
		return strings.TrimSpace(pass), nil
	}

	return string(passBytes), nil
}

// newRetryPolicy creates a retry policy suitable for long-running operations.
func newRetryPolicy() common.RetryPolicy {
	return common.NewRetryPolicyWithOptions(
		common.WithMaximumNumberAttempts(MaxRetryAttempts),
		common.WithFixedBackoff(RetryBackoffSecs*time.Second),
		common.WithShouldRetryOperation(func(r common.OCIOperationResponse) bool {
			if r.Error != nil {
				if serviceErr, ok := r.Error.(common.ServiceError); ok {
					switch serviceErr.GetHTTPStatusCode() {
					case 429, 500, 502, 503, 504:
						return true
					}
				}
			}
			return false
		}),
	)
}

// OciImage represents an OCI custom image.
type OciImage struct {
	ID             string
	DisplayName    string
	LifecycleState string
	TimeCreated    *time.Time
}

// ListImages lists custom images in the compartment.
func (c *Client) ListImages(ctx context.Context, prefix string) ([]OciImage, error) {
	req := core.ListImagesRequest{
		CompartmentId: common.String(c.Config.OCI.CompartmentOCID),
	}

	if prefix != "" {
		req.DisplayName = common.String(prefix)
	}

	var images []OciImage

	for {
		resp, err := c.Compute.ListImages(ctx, req)
		if err != nil {
			return nil, fmt.Errorf("failed to list images: %w", err)
		}

		for _, img := range resp.Items {
			var timeCreated *time.Time
			if img.TimeCreated != nil {
				t := img.TimeCreated.Time
				timeCreated = &t
			}
			images = append(images, OciImage{
				ID:             *img.Id,
				DisplayName:    *img.DisplayName,
				LifecycleState: string(img.LifecycleState),
				TimeCreated:    timeCreated,
			})
		}

		if resp.OpcNextPage == nil {
			break
		}
		req.Page = resp.OpcNextPage
	}

	return images, nil
}

// GetImageStatus returns the lifecycle state of an image.
func (c *Client) GetImageStatus(ctx context.Context, imageID string) (string, error) {
	req := core.GetImageRequest{
		ImageId: common.String(imageID),
	}

	resp, err := c.Compute.GetImage(ctx, req)
	if err != nil {
		if serviceErr, ok := err.(common.ServiceError); ok {
			if serviceErr.GetHTTPStatusCode() == 404 {
				return "NOT_FOUND", nil
			}
		}
		return "", fmt.Errorf("failed to get image status: %w", err)
	}

	return string(resp.LifecycleState), nil
}

// truncateID truncates an OCID for display.
func truncateID(id string) string {
	if len(id) > 20 {
		return id[:20] + "..."
	}
	return id
}

