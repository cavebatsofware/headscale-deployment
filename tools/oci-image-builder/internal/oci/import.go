package oci

import (
	"context"
	"fmt"
	"time"

	"github.com/oracle/oci-go-sdk/v65/common"
	"github.com/oracle/oci-go-sdk/v65/core"
)

// Import imports images from Object Storage as OCI Custom Images.
func (c *Client) Import(ctx context.Context, objectNames []string) (map[string]string, error) {
	namespace, err := c.GetNamespace(ctx)
	if err != nil {
		return nil, err
	}

	timestamp := time.Now().Format("20060102-150405")
	imageIDs := make(map[string]string)

	for _, objectName := range objectNames {
		imageName := extractImageName(objectName)
		displayName := fmt.Sprintf("%s-nixos-%s", imageName, timestamp)

		c.Logger.Logf("Importing %s as OCI Custom Image...", objectName)
		c.Logger.Logf("  Display name: %s", displayName)
		c.Logger.Logf("  Source bucket: %s", c.Config.OCI.BucketName)

		imageSource := core.ImageSourceViaObjectStorageTupleDetails{
			NamespaceName:          common.String(namespace),
			BucketName:             common.String(c.Config.OCI.BucketName),
			ObjectName:             common.String(objectName),
			SourceImageType:        core.ImageSourceDetailsSourceImageTypeQcow2,
			OperatingSystem:        common.String("NixOS"),
			OperatingSystemVersion: common.String("24.11"),
		}

		req := core.CreateImageRequest{
			CreateImageDetails: core.CreateImageDetails{
				CompartmentId:      common.String(c.Config.OCI.CompartmentOCID),
				DisplayName:        common.String(displayName),
				ImageSourceDetails: imageSource,
				LaunchMode:         core.CreateImageDetailsLaunchModeParavirtualized,
			},
		}

		resp, err := c.Compute.CreateImage(ctx, req)
		if err != nil {
			c.Logger.Logf("  Import failed: %v", err)
			return nil, fmt.Errorf("import failed for %s: %w", imageName, err)
		}

		imageID := *resp.Id
		c.Logger.Logf("  Import initiated: %s", imageID)
		imageIDs[imageName] = imageID
	}

	return imageIDs, nil
}

// WaitForImages waits for all images to become available.
func (c *Client) WaitForImages(ctx context.Context, imageIDs map[string]string) error {
	initialDelay := time.Duration(c.Config.OCI.InitialDelaySecs) * time.Second
	pollInterval := time.Duration(c.Config.OCI.PollIntervalSecs) * time.Second
	maxWait := time.Duration(c.Config.OCI.MaxWaitSecs) * time.Second

	for imageName, imageID := range imageIDs {
		if err := c.waitForImage(ctx, imageName, imageID, initialDelay, pollInterval, maxWait); err != nil {
			return err
		}
	}

	return nil
}

// waitForImage waits for a single image to become available.
func (c *Client) waitForImage(ctx context.Context, imageName, imageID string, initialDelay, pollInterval, maxWait time.Duration) error {
	c.Logger.Logf("Waiting for image %s to be available...", truncateID(imageID))
	c.Logger.Logf("  Initial delay: %ds, poll interval: %ds, max wait: %ds",
		int(initialDelay.Seconds()), int(pollInterval.Seconds()), int(maxWait.Seconds()))

	// Initial delay
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(initialDelay):
	}

	startTime := time.Now()

	for {
		elapsed := time.Since(startTime)
		elapsedSecs := int(elapsed.Seconds())

		status, err := c.GetImageStatus(ctx, imageID)
		if err != nil {
			return fmt.Errorf("failed to get status for %s: %w", imageName, err)
		}

		switch status {
		case "AVAILABLE":
			c.Logger.Logf("  Image is AVAILABLE (%ds elapsed)", elapsedSecs)
			return nil

		case "IMPORTING":
			c.Logger.Logf("  Status: IMPORTING (%ds elapsed)", elapsedSecs)

		case "NOT_FOUND":
			c.Logger.Logf("  Status: NOT_FOUND - waiting for import to register (%ds elapsed)", elapsedSecs)

		default:
			return fmt.Errorf("unexpected state for image %s: %s", imageName, status)
		}

		if elapsed >= maxWait {
			c.Logger.Logf("  Timeout waiting for image after %ds", elapsedSecs)
			return fmt.Errorf("timeout waiting for image %s after %ds", imageName, elapsedSecs)
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(pollInterval):
		}
	}
}

// extractImageName extracts the base image name from an object name.
// e.g., "headscale-20240115-123456.qcow2" -> "headscale"
func extractImageName(objectName string) string {
	for i, c := range objectName {
		if c == '-' {
			return objectName[:i]
		}
	}
	// No dash found, return without extension
	if len(objectName) > 6 && objectName[len(objectName)-6:] == ".qcow2" {
		return objectName[:len(objectName)-6]
	}
	return objectName
}
