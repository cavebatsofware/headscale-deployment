package oci

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/oracle/oci-go-sdk/v65/common"
	"github.com/oracle/oci-go-sdk/v65/objectstorage/transfer"
)

// Upload uploads images to Object Storage.
func (c *Client) Upload(ctx context.Context, imageNames []string) ([]string, error) {
	namespace, err := c.GetNamespace(ctx)
	if err != nil {
		return nil, err
	}

	timestamp := time.Now().Format("20060102-150405")
	var objectNames []string

	for _, name := range imageNames {
		qcowPath := filepath.Join(fmt.Sprintf("result-%s", name), "nixos.qcow2")

		fileInfo, err := os.Stat(qcowPath)
		if err != nil {
			return nil, fmt.Errorf("image not found: %s (run build first)", qcowPath)
		}

		totalBytes := fileInfo.Size()
		objectName := fmt.Sprintf("%s-%s.qcow2", name, timestamp)

		c.Logger.Logf("Uploading %s (%d MB) to bucket '%s'...",
			name, totalBytes/(1024*1024), c.Config.OCI.BucketName)
		c.Logger.Logf("  Object name: %s", objectName)

		uploadManager := transfer.NewUploadManager()

		// Progress callback for multipart upload parts
		callback := func(part transfer.MultiPartUploadPart) {
			if part.Err != nil {
				c.Logger.Logf("  Part %d error: %v", part.PartNum, part.Err)
				return
			}

			bytesSent := int64(part.PartNum) * (totalBytes / int64(part.TotalParts))
			if part.PartNum == part.TotalParts {
				bytesSent = totalBytes
			}
			percent := float64(bytesSent) / float64(totalBytes) * 100

			c.Logger.Logf("  Part %d/%d complete (%.1f%%)", part.PartNum, part.TotalParts, percent)
		}

		req := transfer.UploadFileRequest{
			UploadRequest: transfer.UploadRequest{
				NamespaceName:                       common.String(namespace),
				BucketName:                          common.String(c.Config.OCI.BucketName),
				ObjectName:                          common.String(objectName),
				ObjectStorageClient:                 &c.ObjectStorage,
				PartSize:                            common.Int64(UploadPartSize),
				AllowMultipartUploads:               common.Bool(true),
				AllowParrallelUploads:               common.Bool(false),
				NumberOfGoroutines:                  common.Int(1),
				EnableMultipartChecksumVerification: common.Bool(true),
				CallBack:                            callback,
			},
			FilePath: qcowPath,
		}

		resp, err := uploadManager.UploadFile(ctx, req)
		if err != nil {
			return nil, fmt.Errorf("upload failed for %s: %w", name, err)
		}

		if resp.Type == transfer.MultipartUpload {
			c.Logger.Logf("  Upload complete (multipart): %s", objectName)
		} else {
			c.Logger.Logf("  Upload complete: %s", objectName)
		}

		objectNames = append(objectNames, objectName)
	}

	return objectNames, nil
}
