use std::sync::Arc;

use futures::{future, Future};
use actix_web::{FromRequest, HttpMessage, HttpRequest};
use actix_web::dev::JsonBody;
use actix_web::error::{Error, JsonPayloadError, ResponseError};
use serde::de::DeserializeOwned;
use sentry_types::protocol::latest::Event;
use sentry_types::{Auth, AuthParseError};

use smith_common::{ProjectId, ProjectIdParseError};
use smith_trove::TroveState;

/// Holds an event and the associated auth header.
#[derive(Debug)]
pub struct ProjectRequest<T: DeserializeOwned + 'static> {
    auth: Auth,
    project_id: ProjectId,
    payload: Option<T>,
    state: Arc<TroveState>,
}

impl<T: DeserializeOwned + 'static> ProjectRequest<T> {
    /// Returns the sentry protocol auth for this request.
    pub fn auth(&self) -> &Auth {
        &self.auth
    }

    /// Returns the project identifier for this request.
    pub fn project_id(&self) -> ProjectId {
        self.project_id
    }

    /// Returns a reference to the payload.
    pub fn payload(&self) -> Option<&T> {
        self.payload.as_ref()
    }

    /// Returns the current trove state.
    pub fn trove_state(&self) -> Arc<TroveState> {
        self.state.clone()
    }

    /// Converts the object into the event.
    pub fn take_payload(&mut self) -> Option<T> {
        self.payload.take()
    }
}

#[derive(Fail, Debug)]
pub enum BadProjectRequest {
    #[fail(display = "invalid project path parameter")]
    BadProject(#[fail(cause)] ProjectIdParseError),
    #[fail(display = "bad x-sentry-auth header")]
    BadAuth(#[fail(cause)] AuthParseError),
    #[fail(display = "bad JSON payload")]
    BadJson(#[fail(cause)] JsonPayloadError),
}

impl ResponseError for BadProjectRequest {}

fn get_auth_from_request<S>(req: &HttpRequest<S>) -> Result<Auth, BadProjectRequest> {
    // try auth from header
    match req.headers()
        .get("x-sentry-auth")
        .and_then(|x| x.to_str().ok())
    {
        Some(auth) => match auth.parse::<Auth>() {
            Ok(val) => return Ok(val),
            Err(err) => return Err(BadProjectRequest::BadAuth(err)),
        },
        None => {}
    }

    // fall back to auth from url
    Auth::from_pairs(
        req.query()
            .iter()
            .map(|&(ref a, ref b)| -> (&str, &str) { (&a, &b) }),
    ).map_err(BadProjectRequest::BadAuth)
}

impl<T: DeserializeOwned + 'static> FromRequest<Arc<TroveState>> for ProjectRequest<T> {
    type Config = ();
    type Result = Box<Future<Item = Self, Error = Error>>;

    #[inline]
    fn from_request(req: &HttpRequest<Arc<TroveState>>, _cfg: &Self::Config) -> Self::Result {
        let auth = match get_auth_from_request(req) {
            Ok(auth) => auth,
            Err(err) => return Box::new(future::err(err.into())),
        };

        let project_id = match req.match_info()
            .get("project")
            .unwrap_or_default()
            .parse()
            .map_err(BadProjectRequest::BadProject)
        {
            Ok(project_id) => project_id,
            Err(err) => return Box::new(future::err(err.into())),
        };

        let state = req.state().clone();
        Box::new(
            JsonBody::new(req.clone())
                .limit(262_144)
                .map_err(|e| BadProjectRequest::BadJson(e).into())
                .map(move |payload| ProjectRequest {
                    auth,
                    project_id,
                    payload: Some(payload),
                    state,
                }),
        )
    }
}

/// Requests to the store endpoint
pub type StoreRequest = ProjectRequest<Event<'static>>;
