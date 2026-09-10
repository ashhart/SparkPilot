use super::*;

/// The unauthenticated proxy binds only loopback/private addresses; other addresses fall back to loopback with a warning.
fn access_bind_address(listen: std::net::IpAddr) -> std::net::IpAddr {
    access_bind_address_from(listen, primary_local_ip())
}

fn access_bind_address_from(
    listen: std::net::IpAddr,
    primary: Option<std::net::IpAddr>,
) -> std::net::IpAddr {
    let candidate = if listen.is_unspecified() {
        primary
    } else {
        Some(listen)
    };
    match candidate {
        Some(address) if sparkd::service_api::lan_scoped(address) => address,
        Some(address) => {
            tracing::warn!(
                %address,
                "Open WebUI access proxy refused a non-private address; binding loopback instead"
            );
            std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST)
        }
        None => std::net::IpAddr::V4(std::net::Ipv4Addr::LOCALHOST),
    }
}

pub(super) async fn configure(
    state: AppState,
    listen: SocketAddr,
    tls_enabled: bool,
    optional_service_tls: Option<Arc<rustls::ServerConfig>>,
) -> Result<AppState, Box<dyn std::error::Error>> {
    // Reserve both service listeners before serving; trust or bind failure disables only the optional service, leaving management available.
    let recipe_available = match sparkd::service_api::verified_open_webui_recipe(&state) {
        Ok(_) => true,
        Err(error) => {
            tracing::warn!(%error, "optional-service recipe unavailable; Open WebUI is disabled");
            false
        }
    };
    let access_port = listen.port().checked_add(1);
    let reserved = [
        spark_privd::backend::OPEN_WEBUI_LOOPBACK_PORT,
        spark_privd::backend::OPEN_WEBUI_GATEWAY_PORT,
    ];
    let ports_valid = access_port
        .is_some_and(|port| !reserved.contains(&listen.port()) && !reserved.contains(&port));
    if recipe_available && !ports_valid {
        tracing::warn!(
            api_port = listen.port(),
            access_port,
            "optional-service ports overlap or overflow; Open WebUI is disabled"
        );
    }
    let (gateway_listener, access_listener) = if recipe_available && ports_valid {
        match tokio::net::TcpListener::bind((
            std::net::Ipv4Addr::LOCALHOST,
            spark_privd::backend::OPEN_WEBUI_GATEWAY_PORT,
        ))
        .await
        {
            Ok(gateway) => {
                let port = access_port.expect("validated optional-service access port");
                let address = access_bind_address(listen.ip());
                match std::net::TcpListener::bind(SocketAddr::new(address, port)) {
                    Ok(access) => (Some(gateway), Some(access)),
                    Err(error) => {
                        tracing::warn!(
                            %error,
                            %address,
                            port,
                            "optional-service access proxy could not bind; Open WebUI is disabled"
                        );
                        (None, None)
                    }
                }
            }
            Err(error) => {
                tracing::warn!(
                    %error,
                    port = spark_privd::backend::OPEN_WEBUI_GATEWAY_PORT,
                    "optional-service inference gateway could not bind; Open WebUI is disabled"
                );
                (None, None)
            }
        }
    } else {
        (None, None)
    };
    let optional_services_available = gateway_listener.is_some() && access_listener.is_some();
    let state = state.with_optional_services_available(optional_services_available);
    if optional_services_available {
        sparkd::service_api::restore_open_webui_route(&state).await;
    }
    if let Some(gateway_listener) = gateway_listener {
        let gateway = sparkd::service_api::inference_gateway_router(state.clone());
        tokio::spawn(async move {
            if let Err(error) = axum::serve(gateway_listener, gateway).await {
                tracing::error!(%error, "Open WebUI inference gateway stopped");
            }
        });
    }
    if let Some(access_listener) = access_listener {
        access_listener.set_nonblocking(true)?;
        let access_proxy = sparkd::service_api::access_proxy_router(state.clone());
        if tls_enabled {
            let tls = axum_server::tls_rustls::RustlsConfig::from_config(
                optional_service_tls.ok_or("optional-service TLS identity is unavailable")?,
            );
            let server = axum_server::tls_rustls::from_tcp_rustls(access_listener, tls)?;
            tokio::spawn(async move {
                if let Err(error) = server.serve(access_proxy.into_make_service()).await {
                    tracing::error!(%error, "Open WebUI TLS access proxy stopped");
                }
            });
        } else {
            let server = axum_server::from_tcp(access_listener)?;
            tokio::spawn(async move {
                if let Err(error) = server.serve(access_proxy.into_make_service()).await {
                    tracing::error!(%error, "Open WebUI development access proxy stopped");
                }
            });
        }
    }

    Ok(state)
}

#[cfg(test)]
mod tests {
    use super::{access_bind_address, access_bind_address_from};
    use std::net::{IpAddr, Ipv4Addr};

    /// BH-29: the unauthenticated Open WebUI proxy binds only where the LAN is, never every interface, an overlay or the internet.
    #[test]
    fn bh_29_the_open_webui_proxy_never_binds_every_interface() {
        let unspecified = IpAddr::V4(Ipv4Addr::UNSPECIFIED);
        let loopback = IpAddr::V4(Ipv4Addr::LOCALHOST);
        let chosen = access_bind_address(unspecified);
        assert!(
            !chosen.is_unspecified(),
            "the proxy would answer on every interface, tailnet included"
        );
        assert!(
            sparkd::service_api::lan_scoped(chosen),
            "whatever this host's default route is, the proxy chose {chosen}"
        );
        for accepted in [
            "192.168.1.20",
            "10.4.0.7",
            "172.16.0.9",
            "172.31.255.2",
            "fd00::1",
            "fdab:1::7",
            "127.0.0.1",
        ] {
            let address: IpAddr = accepted.parse().unwrap();
            assert_eq!(
                access_bind_address_from(unspecified, Some(address)),
                address,
                "{accepted} is the LAN and is followed"
            );
            assert_eq!(
                access_bind_address_from(address, None),
                address,
                "an explicit LAN listen address is honoured as it is"
            );
        }
        for rejected in [
            "203.0.113.5",
            "8.8.8.8",
            "100.64.0.1",
            "100.127.255.254",
            "172.32.0.1",
            "0.0.0.0",
            "2001:db8::1",
            "::",
        ] {
            let address: IpAddr = rejected.parse().unwrap();
            assert_eq!(
                access_bind_address_from(unspecified, Some(address)),
                loopback,
                "{rejected} as the default route must fall back to loopback"
            );
            assert_eq!(
                access_bind_address_from(address, Some(address)),
                loopback,
                "{rejected} as an explicit listen address must fall back to loopback"
            );
        }
        assert_eq!(
            access_bind_address_from(unspecified, None),
            loopback,
            "no default route at all leaves the proxy on loopback"
        );
    }
}
