//! `nvim_ade_server`: the background service behind ade.nvim.
//!
//! The service is started by Neovim, one instance per user, and speaks
//! JSON-RPC 2.0 with line framing over a unix socket (a named pipe on
//! Windows). It holds ACP agent processes and relays raw ACP JSON-RPC between
//! them and whichever front end is attached.
//!
//! See `service/PROTOCOL.md` for the api_version 2 contract and
//! `service/README.md` for paths, subcommands and how to build.

// Nightly feature: `std::random` (issue #130703) provides randomness from the
// standard library, used to generate the front-end token without pulling in a
// `rand` dependency. See "Nightly features" in service/README.md.
#![feature(random)]

pub mod hub;
#[cfg(unix)]
pub mod install;
pub mod output;
pub mod paths;
pub mod policy;
pub mod protocol;
pub mod recorder;
pub mod relay;
pub mod runtime;
pub mod server;
pub mod store;
pub mod team;
pub mod token;
pub mod transport;

/// Version of the front-end (Neovim) <-> service protocol. Integer, bumped on
/// incompatible changes.
pub const API_VERSION: i64 = 6;

/// Version of this service, taken from `Cargo.toml`.
pub const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");
