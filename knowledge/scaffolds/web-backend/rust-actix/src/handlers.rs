use actix_web::{web, HttpResponse};
use crate::models::{MessageResponse, HealthResponse};

pub async fn hello() -> HttpResponse {
    let response = MessageResponse {
        message: "Hello, World!".to_string(),
    };
    HttpResponse::Ok().json(response)
}

pub async fn hello_name(path: web::Path<String>) -> HttpResponse {
    let name = path.into_inner();
    let response = MessageResponse {
        message: format!("Hello, {}!", name),
    };
    HttpResponse::Ok().json(response)
}

pub async fn health() -> HttpResponse {
    let response = HealthResponse {
        status: "ok".to_string(),
    };
    HttpResponse::Ok().json(response)
}
