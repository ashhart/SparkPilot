//! Web search and page reading performed by the runtime, never by the phone or the inference container.
pub mod audited_transport;
pub mod backend;
pub mod extract;
pub mod guard;
pub mod ledger;
pub mod live;
pub mod outbound;
pub mod policy;
pub mod redact;
pub mod robots;
pub mod session;
pub mod tool_loop;
