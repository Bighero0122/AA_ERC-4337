use actix_web::web::{Data, Json};

use crate::errors::ApiError;
use crate::helpers::respond_json;
use crate::models::hello_world::HelloWorld;
use crate::services::hello_world_service::HelloWorldService;

pub async fn hello_world(service: Data<HelloWorldService>) -> Result<Json<HelloWorld>, ApiError> {
    let hello = service.hello_world()?;
    respond_json(hello)
}
