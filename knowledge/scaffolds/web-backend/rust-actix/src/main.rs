mod handlers;
mod models;

use actix_web::{web, App, HttpServer, middleware::Logger};

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    env_logger::init_from_env(env_logger::Env::default().default_filter_or("info"));

    log::info!("Starting server at http://127.0.0.1:8080");

    HttpServer::new(|| {
        App::new()
            .wrap(Logger::default())
            .service(
                web::scope("/api")
                    .route("/hello", web::get().to(handlers::hello))
                    .route("/hello/{name}", web::get().to(handlers::hello_name))
                    .route("/health", web::get().to(handlers::health))
            )
    })
    .bind("127.0.0.1:8080")?
    .run()
    .await
}
