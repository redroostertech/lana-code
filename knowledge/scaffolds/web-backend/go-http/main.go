package main

import (
	"log"
	"net/http"

	"github.com/example/my-app/handlers"
	"github.com/example/my-app/middleware"
)

func main() {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/hello", handlers.Hello)
	mux.HandleFunc("GET /api/hello/{name}", handlers.HelloName)
	mux.HandleFunc("GET /api/health", handlers.Health)

	handler := middleware.Logging(mux)

	log.Println("Server starting on :8080")
	if err := http.ListenAndServe(":8080", handler); err != nil {
		log.Fatal(err)
	}
}
