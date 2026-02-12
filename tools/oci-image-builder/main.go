// Package main is the entry point for oci-image-builder.
package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"oci-image-builder/internal/build"
	"oci-image-builder/internal/config"
	"oci-image-builder/internal/oci"
	"oci-image-builder/internal/state"
)

var (
	cfgFile string
	verbose bool
	logFile string
)

func main() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

var rootCmd = &cobra.Command{
	Use:   "oci-image-builder",
	Short: "Build and upload NixOS images to OCI",
	Long: `OCI Image Builder - Build and upload NixOS images to Oracle Cloud Infrastructure.

This tool automates the complete image lifecycle:
  1. Build NixOS QCOW2 images (local or remote ARM64)
  2. Upload to OCI Object Storage
  3. Import as OCI Custom Images`,
}

func init() {
	rootCmd.PersistentFlags().StringVarP(&cfgFile, "config", "c", "", "config file (default: ~/.config/oci-image-builder/config.toml)")
	rootCmd.PersistentFlags().BoolVarP(&verbose, "verbose", "v", false, "verbose output")
	rootCmd.PersistentFlags().StringVarP(&logFile, "log-file", "l", "", "log file path")

	buildCmd.Flags().Bool("local-only", false, "build all images locally (skip remote ARM64 builder)")
	buildCmd.Flags().Bool("build-only", false, "skip upload after build")
	allCmd.Flags().Bool("local-only", false, "build all images locally")
	listCmd.Flags().String("prefix", "", "filter by name prefix")

	rootCmd.AddCommand(initCmd)
	rootCmd.AddCommand(buildCmd)
	rootCmd.AddCommand(uploadCmd)
	rootCmd.AddCommand(importCmd)
	rootCmd.AddCommand(allCmd)
	rootCmd.AddCommand(listCmd)
	rootCmd.AddCommand(statusCmd)
	rootCmd.AddCommand(stateCmd)
	rootCmd.AddCommand(resumeCmd)
	rootCmd.AddCommand(statsCmd)
}

var initCmd = &cobra.Command{
	Use:   "init",
	Short: "Initialize configuration file",
	RunE: func(cmd *cobra.Command, args []string) error {
		path, err := config.InitConfigFile()
		if err != nil {
			return err
		}
		fmt.Printf("Configuration file created at: %s\n", path)
		fmt.Println("Edit this file to set your OCI compartment OCID and other settings.")
		return nil
	},
}

var buildCmd = &cobra.Command{
	Use:   "build [IMAGE...]",
	Short: "Build NixOS images",
	Long:  "Build NixOS images locally or on remote ARM64 builder. If no images specified, builds all.",
	RunE: func(cmd *cobra.Command, args []string) error {
		localOnly, _ := cmd.Flags().GetBool("local-only")
		buildOnly, _ := cmd.Flags().GetBool("build-only")

		cfg, err := config.Load(cfgFile)
		if err != nil {
			return err
		}

		imageNames := normalizeImages(args, cfg)

		needSSH := !localOnly && needsRemoteBuild(cfg, imageNames)
		if err := build.CheckPrerequisites(needSSH); err != nil {
			return err
		}

		return runBuild(cfg, imageNames, localOnly, buildOnly)
	},
}

var uploadCmd = &cobra.Command{
	Use:   "upload [IMAGE...]",
	Short: "Upload previously built images to OCI",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load(cfgFile)
		if err != nil {
			return err
		}

		imageNames := normalizeImages(args, cfg)
		return runUpload(cfg, imageNames)
	},
}

var importCmd = &cobra.Command{
	Use:   "import [OBJECT...]",
	Short: "Import images from Object Storage to OCI Compute",
	Long:  "Import images from Object Storage (e.g., headscale-20240115.qcow2)",
	RunE: func(cmd *cobra.Command, args []string) error {
		if len(args) == 0 {
			return fmt.Errorf("at least one object name is required")
		}

		cfg, err := config.Load(cfgFile)
		if err != nil {
			return err
		}

		return runImport(cfg, args)
	},
}

var allCmd = &cobra.Command{
	Use:   "all [IMAGE...]",
	Short: "Run all stages: build, upload, import",
	RunE: func(cmd *cobra.Command, args []string) error {
		localOnly, _ := cmd.Flags().GetBool("local-only")

		cfg, err := config.Load(cfgFile)
		if err != nil {
			return err
		}

		imageNames := normalizeImages(args, cfg)

		needSSH := !localOnly && needsRemoteBuild(cfg, imageNames)
		if err := build.CheckPrerequisites(needSSH); err != nil {
			return err
		}

		return runAll(cfg, imageNames, localOnly)
	},
}

var listCmd = &cobra.Command{
	Use:   "list",
	Short: "List images in OCI compartment",
	RunE: func(cmd *cobra.Command, args []string) error {
		prefix, _ := cmd.Flags().GetString("prefix")

		cfg, err := config.Load(cfgFile)
		if err != nil {
			return err
		}

		client, err := oci.NewClient(cfg)
		if err != nil {
			return err
		}

		images, err := client.ListImages(context.Background(), prefix)
		if err != nil {
			return err
		}

		for _, img := range images {
			fmt.Printf("%s\t%s\t%s\n", img.ID, img.DisplayName, img.LifecycleState)
		}

		return nil
	},
}

var statusCmd = &cobra.Command{
	Use:   "status [OCID...]",
	Short: "Check image lifecycle states",
	RunE: func(cmd *cobra.Command, args []string) error {
		if len(args) == 0 {
			return fmt.Errorf("at least one image OCID is required")
		}

		cfg, err := config.Load(cfgFile)
		if err != nil {
			return err
		}

		client, err := oci.NewClient(cfg)
		if err != nil {
			return err
		}

		for _, id := range args {
			status, err := client.GetImageStatus(context.Background(), id)
			if err != nil {
				fmt.Printf("%s: error - %v\n", id, err)
			} else {
				fmt.Printf("%s: %s\n", id, status)
			}
		}

		return nil
	},
}

var stateCmd = &cobra.Command{
	Use:   "state",
	Short: "Show current pipeline state",
	RunE: func(cmd *cobra.Command, args []string) error {
		mgr, err := state.NewManager()
		if err != nil {
			return err
		}

		pstate, err := mgr.Load()
		if err != nil {
			return err
		}

		if pstate == nil {
			fmt.Println("No saved state found.")
			return nil
		}

		fmt.Printf("Run ID:    %s\n", pstate.RunID)
		fmt.Printf("Started:   %s\n", pstate.StartedAt.Format("2006-01-02 15:04:05"))
		fmt.Printf("Updated:   %s\n", pstate.UpdatedAt.Format("2006-01-02 15:04:05"))
		fmt.Printf("Stage:     %s\n", pstate.Stage)
		fmt.Printf("Complete:  %v\n", pstate.Complete)
		fmt.Printf("\nImages:\n")
		for _, img := range pstate.Images {
			fmt.Printf("  %s:\n", img.Name)
			fmt.Printf("    Stage:      %s\n", img.Stage)
			if img.LocalPath != "" {
				fmt.Printf("    LocalPath:  %s\n", img.LocalPath)
			}
			if img.ObjectName != "" {
				fmt.Printf("    ObjectName: %s\n", img.ObjectName)
			}
			if img.ImageID != "" {
				fmt.Printf("    ImageID:    %s\n", img.ImageID)
			}
			if img.Error != "" {
				fmt.Printf("    Error:      %s\n", img.Error)
			}
		}

		fmt.Printf("\nState file: %s\n", mgr.StatePath())
		return nil
	},
}

var resumeCmd = &cobra.Command{
	Use:   "resume",
	Short: "Resume an interrupted pipeline from saved state",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load(cfgFile)
		if err != nil {
			return err
		}

		mgr, err := state.NewManager()
		if err != nil {
			return err
		}

		pstate, err := mgr.Load()
		if err != nil {
			return err
		}

		if pstate == nil {
			return fmt.Errorf("no saved state to resume. Run 'all' or 'build' first")
		}

		if pstate.Complete {
			fmt.Println("Previous run completed successfully. Nothing to resume.")
			fmt.Println("Run 'state' to see details or start a new run with 'all'.")
			return nil
		}

		fmt.Printf("Resuming from stage: %s\n", pstate.Stage)

		var imageNames []string
		for _, img := range pstate.Images {
			imageNames = append(imageNames, img.Name)
		}

		switch pstate.Stage {
		case "build":
			fmt.Println("Resuming from build stage...")
			return resumeFromBuild(cfg, mgr, imageNames)
		case "upload":
			fmt.Println("Resuming from upload stage...")
			return resumeFromUpload(cfg, mgr, imageNames)
		case "import":
			fmt.Println("Resuming from import stage...")
			return resumeFromImport(cfg, mgr)
		default:
			return fmt.Errorf("unknown stage: %s", pstate.Stage)
		}
	},
}

var statsCmd = &cobra.Command{
	Use:   "stats",
	Short: "Display build statistics from last pipeline run",
	RunE: func(cmd *cobra.Command, args []string) error {
		mgr, err := state.NewManager()
		if err != nil {
			return err
		}

		pstate, err := mgr.Load()
		if err != nil {
			return err
		}

		if pstate == nil {
			fmt.Println("No saved state found. Run a build first.")
			return nil
		}

		stats := mgr.GetStatistics()
		if stats == nil {
			fmt.Println("No statistics available.")
			return nil
		}

		fmt.Printf("=== Pipeline Statistics (Run: %s) ===\n\n", stats.RunID)
		fmt.Printf("Total Duration:     %s\n\n", state.FormatDuration(stats.TotalDuration))

		fmt.Println("Stage Durations:")
		fmt.Printf("  Build:            %s\n", state.FormatDuration(stats.BuildDuration))
		fmt.Printf("  Upload:           %s\n", state.FormatDuration(stats.UploadDuration))
		fmt.Printf("  Import:           %s\n\n", state.FormatDuration(stats.ImportDuration))

		if stats.TotalBytesUploaded > 0 {
			fmt.Println("Upload Statistics:")
			fmt.Printf("  Total Uploaded:   %.2f GB\n", float64(stats.TotalBytesUploaded)/(1024*1024*1024))
			fmt.Printf("  Throughput:       %.2f MB/s\n\n", stats.UploadThroughputMB)
		}

		if len(stats.ImageStats) > 0 {
			fmt.Println("Per-Image Breakdown:")
			fmt.Printf("  %-12s %10s %10s %10s %10s %10s\n",
				"Image", "Build", "Upload", "Import", "Total", "MB/s")
			fmt.Println("  " + strings.Repeat("-", 64))
			for _, img := range stats.ImageStats {
				throughput := "-"
				if img.UploadThroughputMB > 0 {
					throughput = fmt.Sprintf("%.2f", img.UploadThroughputMB)
				}
				fmt.Printf("  %-12s %10s %10s %10s %10s %10s\n",
					img.Name,
					state.FormatDuration(img.BuildDuration),
					state.FormatDuration(img.UploadDuration),
					state.FormatDuration(img.ImportDuration),
					state.FormatDuration(img.TotalDuration),
					throughput)
			}
		}

		fmt.Printf("\nState file: %s\n", mgr.StatePath())
		return nil
	},
}

func resumeFromBuild(cfg *config.Config, mgr *state.Manager, imageNames []string) error {
	var needBuild []string
	for _, name := range imageNames {
		if !mgr.ShouldSkipBuild(name) {
			needBuild = append(needBuild, name)
		} else {
			fmt.Printf("  Skipping build for %s (already built)\n", name)
		}
	}

	if len(needBuild) == 0 {
		fmt.Println("All images already built, proceeding to upload...")
		mgr.SetStage("upload")
		return resumeFromUpload(cfg, mgr, imageNames)
	}

	builder := build.NewBuilder(cfg, false)
	builder.SetLogFunc(func(msg string) {
		fmt.Println(msg)
	})

	results, err := builder.Build(context.Background(), needBuild)
	if err != nil {
		return err
	}

	for name, result := range results {
		mgr.UpdateImage(name, func(img *state.ImageState) {
			img.LocalPath = result.OutputPath
			img.Stage = "build_complete"
		})
	}

	mgr.SetStage("upload")
	return resumeFromUpload(cfg, mgr, imageNames)
}

func resumeFromUpload(cfg *config.Config, mgr *state.Manager, imageNames []string) error {
	var needUpload []string
	for _, name := range imageNames {
		if !mgr.ShouldSkipUpload(name) {
			needUpload = append(needUpload, name)
		} else {
			fmt.Printf("  Skipping upload for %s (already uploaded)\n", name)
		}
	}

	client, err := oci.NewClient(cfg)
	if err != nil {
		return err
	}
	client.SetLogFunc(func(msg string) {
		fmt.Println(msg)
	})

	if len(needUpload) > 0 {
		objects, err := client.Upload(context.Background(), needUpload)
		if err != nil {
			return err
		}

		for i, name := range needUpload {
			mgr.UpdateImage(name, func(img *state.ImageState) {
				img.ObjectName = objects[i]
				img.Stage = "upload_complete"
			})
		}
	}

	mgr.SetStage("import")
	return resumeFromImport(cfg, mgr)
}

func resumeFromImport(cfg *config.Config, mgr *state.Manager) error {
	client, err := oci.NewClient(cfg)
	if err != nil {
		return err
	}
	client.SetLogFunc(func(msg string) {
		fmt.Println(msg)
	})

	pstate := mgr.GetState()

	existingIDs := mgr.GetImageIDs()
	if len(existingIDs) > 0 {
		fmt.Println("Checking status of previously initiated imports...")
		if err := client.WaitForImages(context.Background(), existingIDs); err != nil {
			return err
		}
	}

	var needImport []string
	for _, img := range pstate.Images {
		if img.ImageID == "" && img.ObjectName != "" {
			needImport = append(needImport, img.ObjectName)
		}
	}

	if len(needImport) > 0 {
		imageIDs, err := client.Import(context.Background(), needImport)
		if err != nil {
			return err
		}

		for name, id := range imageIDs {
			mgr.UpdateImage(name, func(img *state.ImageState) {
				img.ImageID = id
				img.Stage = "importing"
			})
		}

		if err := client.WaitForImages(context.Background(), imageIDs); err != nil {
			return err
		}

		for name := range imageIDs {
			mgr.UpdateImage(name, func(img *state.ImageState) {
				img.Stage = "complete"
			})
		}
	}

	for _, img := range pstate.Images {
		mgr.UpdateImage(img.Name, func(s *state.ImageState) {
			s.Stage = "complete"
		})
	}

	mgr.SetStage("complete")
	mgr.MarkComplete()

	fmt.Println("\n=== Pipeline Complete ===")

	if stats := mgr.GetStatistics(); stats != nil {
		fmt.Println("\n=== Build Statistics ===")
		fmt.Printf("Total Duration: %s\n", state.FormatDuration(stats.TotalDuration))
		fmt.Printf("  Build: %s | Upload: %s | Import: %s\n",
			state.FormatDuration(stats.BuildDuration),
			state.FormatDuration(stats.UploadDuration),
			state.FormatDuration(stats.ImportDuration))
		if stats.TotalBytesUploaded > 0 {
			fmt.Printf("Upload: %.2f GB at %.2f MB/s\n",
				float64(stats.TotalBytesUploaded)/(1024*1024*1024),
				stats.UploadThroughputMB)
		}
	}

	fmt.Println("\n=== Add to terraform.tfvars ===")
	imageIDs := mgr.GetImageIDs()
	for name, id := range imageIDs {
		img := cfg.GetImage(name)
		if img != nil && img.TerraformVar != "" {
			fmt.Printf("%s = \"%s\"\n", img.TerraformVar, id)
		} else {
			fmt.Printf("%s_image_ocid = \"%s\"\n", name, id)
		}
	}

	return nil
}

// Helper functions

func normalizeImages(args []string, cfg *config.Config) []string {
	if len(args) == 0 {
		return cfg.GetAllImageNames()
	}
	return args
}

func needsRemoteBuild(cfg *config.Config, imageNames []string) bool {
	for _, name := range imageNames {
		img := cfg.GetImage(name)
		if img != nil && img.Arch == config.ArchAarch64 {
			return true
		}
	}
	return false
}

func runBuild(cfg *config.Config, imageNames []string, localOnly bool, buildOnly bool) error {
	builder := build.NewBuilder(cfg, localOnly)
	builder.SetLogFunc(func(msg string) {
		fmt.Println(msg)
	})

	results, err := builder.Build(context.Background(), imageNames)
	if err != nil {
		return err
	}

	for name, result := range results {
		if result.Error != nil {
			fmt.Printf("%s: ERROR - %v\n", name, result.Error)
		} else {
			fmt.Printf("%s: %s (%d MB)\n", name, result.OutputPath, result.SizeBytes/(1024*1024))
		}
	}

	if buildOnly {
		return nil
	}

	return runUpload(cfg, imageNames)
}

func runUpload(cfg *config.Config, imageNames []string) error {
	client, err := oci.NewClient(cfg)
	if err != nil {
		return err
	}
	client.SetLogFunc(func(msg string) {
		fmt.Println(msg)
	})

	objects, err := client.Upload(context.Background(), imageNames)
	if err != nil {
		return err
	}

	fmt.Println("\nUploaded objects:")
	for _, obj := range objects {
		fmt.Printf("  %s\n", obj)
	}

	return nil
}

func runImport(cfg *config.Config, objects []string) error {
	client, err := oci.NewClient(cfg)
	if err != nil {
		return err
	}
	client.SetLogFunc(func(msg string) {
		fmt.Println(msg)
	})

	imageIDs, err := client.Import(context.Background(), objects)
	if err != nil {
		return err
	}

	fmt.Println("\nWaiting for images to be available...")
	if err := client.WaitForImages(context.Background(), imageIDs); err != nil {
		return err
	}

	fmt.Println("\n=== Add to terraform.tfvars ===")
	for name, id := range imageIDs {
		img := cfg.GetImage(name)
		if img != nil && img.TerraformVar != "" {
			fmt.Printf("%s = \"%s\"\n", img.TerraformVar, id)
		} else {
			fmt.Printf("%s_image_ocid = \"%s\"\n", name, id)
		}
	}

	return nil
}

func runAll(cfg *config.Config, imageNames []string, localOnly bool) error {
	fmt.Println("=== Build Stage ===")
	builder := build.NewBuilder(cfg, localOnly)
	builder.SetLogFunc(func(msg string) {
		fmt.Println(msg)
	})

	_, err := builder.Build(context.Background(), imageNames)
	if err != nil {
		return err
	}

	fmt.Println("\n=== Upload Stage ===")
	client, err := oci.NewClient(cfg)
	if err != nil {
		return err
	}
	client.SetLogFunc(func(msg string) {
		fmt.Println(msg)
	})

	objects, err := client.Upload(context.Background(), imageNames)
	if err != nil {
		return err
	}

	fmt.Println("\n=== Import Stage ===")
	imageIDs, err := client.Import(context.Background(), objects)
	if err != nil {
		return err
	}

	fmt.Println("\nWaiting for images to be available...")
	if err := client.WaitForImages(context.Background(), imageIDs); err != nil {
		return err
	}

	fmt.Println("\n=== Add to terraform.tfvars ===")
	for name, id := range imageIDs {
		img := cfg.GetImage(name)
		if img != nil && img.TerraformVar != "" {
			fmt.Printf("%s = \"%s\"\n", img.TerraformVar, id)
		} else {
			fmt.Printf("%s_image_ocid = \"%s\"\n", name, id)
		}
	}

	return nil
}
