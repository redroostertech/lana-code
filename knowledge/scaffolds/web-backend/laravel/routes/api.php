<?php

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;

Route::get('/hello', function () {
    return response()->json(['message' => 'Hello, World!']);
});

Route::get('/hello/{name}', function (string $name) {
    return response()->json(['message' => "Hello, {$name}!"]);
});

Route::get('/user', function (Request $request) {
    return $request->user();
})->middleware('auth:sanctum');
