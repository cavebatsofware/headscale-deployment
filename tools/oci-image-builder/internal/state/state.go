// Package state handles persisting and resuming pipeline state.
package state

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/pelletier/go-toml/v2"
)

// StageTimings tracks timing for all stages of an image build.
// Note: Using time.Time (not *time.Time) because go-toml/v2 serializes pointer
// times as quoted strings which fail to deserialize. Zero value means "not set".
type StageTimings struct {
	BuildStartedAt    time.Time `toml:"build_started_at,omitzero"`
	BuildCompletedAt  time.Time `toml:"build_completed_at,omitzero"`
	UploadStartedAt   time.Time `toml:"upload_started_at,omitzero"`
	UploadCompletedAt time.Time `toml:"upload_completed_at,omitzero"`
	ImportStartedAt   time.Time `toml:"import_started_at,omitzero"`
	ImportCompletedAt time.Time `toml:"import_completed_at,omitzero"`
}

// ImageMetrics tracks size and throughput metrics for an image.
type ImageMetrics struct {
	BuildSizeBytes  int64 `toml:"build_size_bytes,omitempty"`
	UploadSizeBytes int64 `toml:"upload_size_bytes,omitempty"`
	UploadParts     int   `toml:"upload_parts,omitempty"`
}

// PipelineStatistics holds computed statistics for display.
type PipelineStatistics struct {
	RunID              string
	TotalDuration      time.Duration
	BuildDuration      time.Duration
	UploadDuration     time.Duration
	ImportDuration     time.Duration
	TotalBytesUploaded int64
	UploadThroughputMB float64
	ImageStats         []ImageStatistics
}

// ImageStatistics holds per-image statistics.
type ImageStatistics struct {
	Name               string
	BuildDuration      time.Duration
	UploadDuration     time.Duration
	ImportDuration     time.Duration
	TotalDuration      time.Duration
	UploadSizeMB       float64
	UploadThroughputMB float64
}

// ImageState tracks the state of a single image through the pipeline.
type ImageState struct {
	Name       string       `toml:"name"`
	LocalPath  string       `toml:"local_path,omitempty"`  // Path to local qcow2
	ObjectName string       `toml:"object_name,omitempty"` // Name in Object Storage
	ImageID    string       `toml:"image_id,omitempty"`    // OCI Custom Image OCID
	Stage      string       `toml:"stage"`                 // pending, build, upload, import, complete, error
	Error      string       `toml:"error,omitempty"`
	Timings    StageTimings `toml:"timings"`
	Metrics    ImageMetrics `toml:"metrics"`
}

// PipelineState tracks the overall pipeline state.
type PipelineState struct {
	RunID       string       `toml:"run_id"`
	StartedAt   time.Time    `toml:"started_at"`
	UpdatedAt   time.Time    `toml:"updated_at"`
	CompletedAt time.Time    `toml:"completed_at,omitzero"`
	Stage       string       `toml:"stage"` // Current overall stage
	Images      []ImageState `toml:"images"`
	Complete    bool         `toml:"complete"`
}

// Manager handles loading and saving pipeline state.
type Manager struct {
	statePath string
	state     *PipelineState
}

// NewManager creates a new state manager.
func NewManager() (*Manager, error) {
	cacheDir, err := os.UserCacheDir()
	if err != nil {
		cacheDir = "/tmp"
	}

	stateDir := filepath.Join(cacheDir, "oci-image-builder")
	if err := os.MkdirAll(stateDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create state directory: %w", err)
	}

	return &Manager{
		statePath: filepath.Join(stateDir, "state.toml"),
	}, nil
}

// Load loads the pipeline state from disk.
func (m *Manager) Load() (*PipelineState, error) {
	data, err := os.ReadFile(m.statePath)
	if os.IsNotExist(err) {
		return nil, nil // No state file, fresh start
	}
	if err != nil {
		return nil, fmt.Errorf("failed to read state file: %w", err)
	}

	var state PipelineState
	if err := toml.Unmarshal(data, &state); err != nil {
		return nil, fmt.Errorf("failed to parse state file: %w", err)
	}

	m.state = &state
	return &state, nil
}

// NewRun creates a new pipeline run.
func (m *Manager) NewRun(imageNames []string) *PipelineState {
	now := time.Now()
	images := make([]ImageState, len(imageNames))
	for i, name := range imageNames {
		images[i] = ImageState{
			Name:  name,
			Stage: "pending",
		}
	}

	m.state = &PipelineState{
		RunID:     now.Format("20060102-150405"),
		StartedAt: now,
		UpdatedAt: now,
		Stage:     "build",
		Images:    images,
		Complete:  false,
	}

	return m.state
}

// Save persists the current state to disk.
func (m *Manager) Save() error {
	if m.state == nil {
		return nil
	}

	m.state.UpdatedAt = time.Now()

	data, err := toml.Marshal(m.state)
	if err != nil {
		return fmt.Errorf("failed to marshal state: %w", err)
	}

	if err := os.WriteFile(m.statePath, data, 0644); err != nil {
		return fmt.Errorf("failed to write state file: %w", err)
	}

	return nil
}

// GetState returns the current state.
func (m *Manager) GetState() *PipelineState {
	return m.state
}

// SetState sets the current state (for resuming).
func (m *Manager) SetState(state *PipelineState) {
	m.state = state
}

// CanResume checks if there's a resumable state.
func (m *Manager) CanResume() bool {
	return m.state != nil && !m.state.Complete
}

// GetImageState returns the state of a specific image.
func (m *Manager) GetImageState(name string) *ImageState {
	if m.state == nil {
		return nil
	}
	for i := range m.state.Images {
		if m.state.Images[i].Name == name {
			return &m.state.Images[i]
		}
	}
	return nil
}

// UpdateImage updates the state of a specific image.
func (m *Manager) UpdateImage(name string, update func(*ImageState)) error {
	if m.state == nil {
		return fmt.Errorf("no active run")
	}

	for i := range m.state.Images {
		if m.state.Images[i].Name == name {
			update(&m.state.Images[i])
			return m.Save()
		}
	}

	return fmt.Errorf("unknown image: %s", name)
}

// SetStage sets the current pipeline stage.
func (m *Manager) SetStage(stage string) error {
	if m.state == nil {
		return fmt.Errorf("no active run")
	}

	m.state.Stage = stage
	return m.Save()
}

// MarkComplete marks the pipeline as complete.
func (m *Manager) MarkComplete() error {
	if m.state == nil {
		return fmt.Errorf("no active run")
	}

	m.state.Complete = true
	m.state.CompletedAt = time.Now()
	return m.Save()
}

// Clear removes the state file.
func (m *Manager) Clear() error {
	if err := os.Remove(m.statePath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to remove state file: %w", err)
	}
	m.state = nil
	return nil
}

// ShouldSkipBuild checks if build can be skipped for an image.
func (m *Manager) ShouldSkipBuild(name string) bool {
	img := m.GetImageState(name)
	if img == nil {
		return false
	}

	// Skip if we have a local path and it exists
	if img.LocalPath != "" {
		if _, err := os.Stat(img.LocalPath); err == nil {
			return true
		}
	}

	return false
}

// ShouldSkipUpload checks if upload can be skipped for an image.
func (m *Manager) ShouldSkipUpload(name string) bool {
	img := m.GetImageState(name)
	if img == nil {
		return false
	}

	// Skip if we have an object name (already uploaded)
	return img.ObjectName != ""
}

// ShouldSkipImport checks if import can be skipped for an image.
func (m *Manager) ShouldSkipImport(name string) bool {
	img := m.GetImageState(name)
	if img == nil {
		return false
	}

	// Skip if we have an image ID (already imported or importing)
	return img.ImageID != ""
}

// GetObjectNames returns object names for images that have been uploaded.
func (m *Manager) GetObjectNames() []string {
	if m.state == nil {
		return nil
	}

	var names []string
	for _, img := range m.state.Images {
		if img.ObjectName != "" {
			names = append(names, img.ObjectName)
		}
	}
	return names
}

// GetImageIDs returns image IDs for images that have been imported.
func (m *Manager) GetImageIDs() map[string]string {
	if m.state == nil {
		return nil
	}

	ids := make(map[string]string)
	for _, img := range m.state.Images {
		if img.ImageID != "" {
			ids[img.Name] = img.ImageID
		}
	}
	return ids
}

// StatePath returns the path to the state file.
func (m *Manager) StatePath() string {
	return m.statePath
}

// RecordStageStart records the start time for a stage.
func (m *Manager) RecordStageStart(imageName, stage string) error {
	now := time.Now()
	return m.UpdateImage(imageName, func(img *ImageState) {
		switch stage {
		case "build":
			img.Timings.BuildStartedAt = now
		case "upload":
			img.Timings.UploadStartedAt = now
		case "import":
			img.Timings.ImportStartedAt = now
		}
	})
}

// RecordStageComplete records the completion time for a stage.
func (m *Manager) RecordStageComplete(imageName, stage string) error {
	now := time.Now()
	return m.UpdateImage(imageName, func(img *ImageState) {
		switch stage {
		case "build":
			img.Timings.BuildCompletedAt = now
		case "upload":
			img.Timings.UploadCompletedAt = now
		case "import":
			img.Timings.ImportCompletedAt = now
		}
	})
}

// RecordUploadMetrics records upload size and part count.
func (m *Manager) RecordUploadMetrics(imageName string, sizeBytes int64, parts int) error {
	return m.UpdateImage(imageName, func(img *ImageState) {
		img.Metrics.UploadSizeBytes = sizeBytes
		img.Metrics.UploadParts = parts
	})
}

// RecordBuildMetrics records build output size.
func (m *Manager) RecordBuildMetrics(imageName string, sizeBytes int64) error {
	return m.UpdateImage(imageName, func(img *ImageState) {
		img.Metrics.BuildSizeBytes = sizeBytes
	})
}

// GetStatistics computes statistics from the current state.
func (m *Manager) GetStatistics() *PipelineStatistics {
	if m.state == nil {
		return nil
	}

	stats := &PipelineStatistics{
		RunID:      m.state.RunID,
		ImageStats: make([]ImageStatistics, 0, len(m.state.Images)),
	}

	// Calculate total duration
	if !m.state.CompletedAt.IsZero() {
		stats.TotalDuration = m.state.CompletedAt.Sub(m.state.StartedAt)
	} else {
		stats.TotalDuration = m.state.UpdatedAt.Sub(m.state.StartedAt)
	}

	var totalUploadBytes int64
	var totalUploadDuration time.Duration

	for _, img := range m.state.Images {
		imgStats := ImageStatistics{Name: img.Name}

		// Build duration
		if !img.Timings.BuildStartedAt.IsZero() && !img.Timings.BuildCompletedAt.IsZero() {
			imgStats.BuildDuration = img.Timings.BuildCompletedAt.Sub(img.Timings.BuildStartedAt)
			stats.BuildDuration += imgStats.BuildDuration
		}

		// Upload duration
		if !img.Timings.UploadStartedAt.IsZero() && !img.Timings.UploadCompletedAt.IsZero() {
			imgStats.UploadDuration = img.Timings.UploadCompletedAt.Sub(img.Timings.UploadStartedAt)
			stats.UploadDuration += imgStats.UploadDuration
			totalUploadDuration += imgStats.UploadDuration
		}

		// Import duration
		if !img.Timings.ImportStartedAt.IsZero() && !img.Timings.ImportCompletedAt.IsZero() {
			imgStats.ImportDuration = img.Timings.ImportCompletedAt.Sub(img.Timings.ImportStartedAt)
			stats.ImportDuration += imgStats.ImportDuration
		}

		// Total for this image
		imgStats.TotalDuration = imgStats.BuildDuration + imgStats.UploadDuration +
			imgStats.ImportDuration

		// Upload metrics
		if img.Metrics.UploadSizeBytes > 0 {
			imgStats.UploadSizeMB = float64(img.Metrics.UploadSizeBytes) / (1024 * 1024)
			totalUploadBytes += img.Metrics.UploadSizeBytes
			stats.TotalBytesUploaded += img.Metrics.UploadSizeBytes

			if imgStats.UploadDuration > 0 {
				imgStats.UploadThroughputMB = imgStats.UploadSizeMB / imgStats.UploadDuration.Seconds()
			}
		}

		stats.ImageStats = append(stats.ImageStats, imgStats)
	}

	// Overall upload throughput
	if totalUploadDuration > 0 && totalUploadBytes > 0 {
		stats.UploadThroughputMB = float64(totalUploadBytes) / (1024 * 1024) / totalUploadDuration.Seconds()
	}

	return stats
}

// FormatDuration formats a duration for display (e.g., "3m12s").
func FormatDuration(d time.Duration) string {
	if d < time.Second {
		return "0s"
	}
	d = d.Round(time.Second)
	h := d / time.Hour
	d -= h * time.Hour
	m := d / time.Minute
	d -= m * time.Minute
	s := d / time.Second

	if h > 0 {
		return fmt.Sprintf("%dh%dm%ds", h, m, s)
	}
	if m > 0 {
		return fmt.Sprintf("%dm%ds", m, s)
	}
	return fmt.Sprintf("%ds", s)
}
