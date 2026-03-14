package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var verbose bool

var rootCmd = &cobra.Command{
	Use:   "mycli",
	Short: "A command-line tool",
	Long:  "mycli is a command-line tool built with Cobra.",
}

func Execute() error {
	return rootCmd.Execute()
}

func init() {
	rootCmd.PersistentFlags().BoolVarP(&verbose, "verbose", "v", false, "enable verbose output")

	rootCmd.AddCommand(greetCmd)
	rootCmd.AddCommand(versionCmd)
}

var greetCmd = &cobra.Command{
	Use:   "greet [name]",
	Short: "Greet someone by name",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		greeting, _ := cmd.Flags().GetString("greeting")
		name := args[0]
		if verbose {
			fmt.Fprintf(os.Stderr, "[verbose] greeting=%q, name=%q\n", greeting, name)
		}
		fmt.Printf("%s, %s!\n", greeting, name)
		return nil
	},
}

func init() {
	greetCmd.Flags().StringP("greeting", "g", "Hello", "greeting to use")
}
