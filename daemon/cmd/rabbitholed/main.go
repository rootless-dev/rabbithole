// Command rabbitholed is the Rabbithole upload daemon.
package main

import (
	"context"
	"os"

	"rabbithole/daemon/internal/app"
)

func main() {
	os.Exit(app.Run(context.Background(), os.Args[1:], os.Stdin, os.Stderr))
}
