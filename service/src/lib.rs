//! `nvim_ade_server`: the background service behind ade.nvim.
//!
//! The service is started by Neovim, one instance per user, and speaks
//! JSON-RPC 2.0 with line framing over a unix socket (a named pipe on
//! Windows). See `service/README.md` for the front-end contract and
//! `.acp-work/contract.md` for the agreed S0 behaviour.

// Nightly feature: `std::random` (issue #130703) provides randomness from the
// standard library, used to generate the front-end token without pulling in a
// `rand` dependency. See "Nightly features" in service/README.md.
#![feature(random)]

pub mod output;
pub mod paths;
pub mod protocol;
pub mod server;
pub mod token;

pub mod transport;

/// Version of the front-end (Neovim) <-> service protocol. Integer, bumped on
/// incompatible changes.
pub const API_VERSION: i64 = 1;

/// Version of this service, taken from `Cargo.toml`.
pub const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");
