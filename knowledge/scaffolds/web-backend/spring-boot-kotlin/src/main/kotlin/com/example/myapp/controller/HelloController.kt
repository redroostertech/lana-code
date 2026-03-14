package com.example.myapp.controller

import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PathVariable
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

@RestController
@RequestMapping("/api")
class HelloController {

    @GetMapping("/hello")
    fun hello(): ResponseEntity<Map<String, String>> {
        return ResponseEntity.ok(mapOf("message" to "Hello, World!"))
    }

    @GetMapping("/hello/{name}")
    fun helloName(@PathVariable name: String): ResponseEntity<Map<String, String>> {
        return ResponseEntity.ok(mapOf("message" to "Hello, $name!"))
    }

}
