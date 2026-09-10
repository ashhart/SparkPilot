use super::*;
use crate::clock::ManualUtcClock;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

/// Fresh source addresses must not grow the limiter past its ceiling (M-1).
#[test]
fn fresh_sources_cannot_grow_the_limiter_without_bound() {
    let (_clock, limiter) = limiter();
    for index in 0..(MAX_BUCKETS as u128 * 3) {
        let ip = IpAddr::V6(Ipv6Addr::from((0x2001_0db8u128 << 96) | (index << 64)));
        assert!(
            limiter
                .admit(Subject::Source(ip), RateClass::General)
                .is_ok()
        );
    }
    assert!(tracked_buckets(&limiter) <= MAX_BUCKETS);
}

/// One host's IPv6 /64 is one budget, and an IPv4-mapped peer is not folded into the IPv6 space.
#[test]
fn ipv6_peers_share_a_budget_per_64() {
    let a = source_prefix("2001:db8::1".parse().unwrap());
    let b = source_prefix("2001:db8::ffff:1".parse().unwrap());
    assert_eq!(a, b);
    let other = source_prefix("2001:db8:0:1::1".parse().unwrap());
    assert_ne!(a, other);
    assert_eq!(
        source_prefix("::ffff:192.0.2.1".parse().unwrap()),
        "192.0.2.1".parse::<IpAddr>().unwrap()
    );
}

fn request_from(peer: &str, client: Option<&str>) -> Request {
    let mut builder = axum::http::Request::builder().uri("/api/v1/pairing/claim");
    if let Some(client) = client {
        builder = builder.header("cf-connecting-ip", client);
    }
    let mut request = builder.body(axum::body::Body::empty()).expect("request");
    request.extensions_mut().insert(ConnectInfo(
        format!("{peer}:40000")
            .parse::<std::net::SocketAddr>()
            .expect("peer"),
    ));
    request
}

fn manual() -> (Arc<ManualMonotonic>, RateLimiter) {
    let monotonic = Arc::new(ManualMonotonic::default());
    (monotonic.clone(), RateLimiter::with_monotonic(monotonic))
}

fn drain(limiter: &RateLimiter, subject: &Subject, class: RateClass) {
    for _ in 0..10_000 {
        if limiter.admit(subject.clone(), class).is_err() {
            return;
        }
    }
    panic!("{subject:?} never ran out of {} budget", class.name());
}

/// BH-28, adapted after tunnel removal: remote overlay traffic cannot starve LAN pairing.
#[test]
fn remote_traffic_cannot_starve_lan_pairing_or_authentication() {
    let (_monotonic, limiter) = manual();
    let lan = unauthenticated_subject(&request_from("192.168.1.44", None));
    let attacker = unauthenticated_subject(&request_from("100.96.1.1", Some("203.0.113.7")));
    let connector = unauthenticated_subject(&request_from("127.0.0.1", None));
    for class in [RateClass::Pairing, RateClass::AuthFailure] {
        drain(&limiter, &attacker, class);
        drain(&limiter, &connector, class);
        assert!(
            limiter.admit(lan.clone(), class).is_ok(),
            "{} on the LAN was starved by remote traffic",
            class.name()
        );
    }
}

/// BH-28: two remote devices are two subjects, so one attacker cannot lock the other out.
#[test]
fn two_remote_clients_never_share_one_bucket() {
    let (_monotonic, limiter) = manual();
    let noisy = unauthenticated_subject(&request_from("100.96.1.1", Some("203.0.113.7")));
    let quiet = unauthenticated_subject(&request_from("100.96.1.2", Some("198.51.100.9")));
    assert_ne!(noisy, quiet, "two remote clients must be two subjects");
    drain(&limiter, &noisy, RateClass::Pairing);
    assert!(
        limiter.admit(quiet, RateClass::Pairing).is_ok(),
        "one remote client spent another's budget"
    );
}

/// BH-28: the header is read only where it cannot be forged, and loopback without it is its own bucket.
#[test]
fn forwarded_headers_never_select_the_rate_limit_bucket() {
    let forged = request_from("192.168.1.44", Some("203.0.113.7"));
    assert_eq!(
        unauthenticated_subject(&forged),
        Subject::Source("192.168.1.44".parse().expect("lan")),
        "a LAN peer must never choose its own bucket"
    );
    let untrusted = request_from("127.0.0.1", Some("203.0.113.7"));
    assert_eq!(
        unauthenticated_subject(&untrusted),
        Subject::Loopback,
        "the header is ignored while the public tunnel is not the published route"
    );
    let tunnelled = request_from("127.0.0.1", Some("203.0.113.7"));
    assert_eq!(unauthenticated_subject(&tunnelled), Subject::Loopback);
    let nonsense = request_from("127.0.0.1", Some("not-an-address"));
    assert_eq!(unauthenticated_subject(&nonsense), Subject::Loopback);
    let bare = request_from("127.0.0.1", None);
    assert_eq!(unauthenticated_subject(&bare), Subject::Loopback);
}

/// BH-28: the shared loopback bucket stands for many clients, so it is generous where a LAN address is not.
#[test]
fn the_shared_loopback_bucket_is_larger_than_one_lan_address() {
    let (_monotonic, limiter) = manual();
    let mut lan_admitted = 0;
    let lan = Subject::Source("192.168.1.44".parse().expect("lan"));
    while limiter.admit(lan.clone(), RateClass::Pairing).is_ok() {
        lan_admitted += 1;
    }
    let mut loopback_admitted = 0;
    while limiter.admit(Subject::Loopback, RateClass::Pairing).is_ok() {
        loopback_admitted += 1;
    }
    assert!(
        loopback_admitted > lan_admitted * 5,
        "loopback admitted {loopback_admitted} against the LAN's {lan_admitted}"
    );
}

/// BH-52: eviction takes the least recently used bucket, so an active subject cannot be evicted into a fresh burst.
#[test]
fn an_evicted_subject_cannot_buy_back_a_burst() {
    let (_monotonic, limiter) = manual();
    let heavy = Subject::Source("198.51.100.1".parse().expect("heavy"));
    drain(&limiter, &heavy, RateClass::Pairing);
    // Fill the table twice over, touching the exhausted subject between insertions.
    for index in 0..(MAX_BUCKETS as u128 * 2) {
        let fresh = IpAddr::V6(Ipv6Addr::from((0x2001_0db8u128 << 96) | (index << 64)));
        let _ = limiter.admit(Subject::Source(fresh), RateClass::Pairing);
        assert!(
            limiter.admit(heavy.clone(), RateClass::Pairing).is_err(),
            "an exhausted subject bought back a burst after {index} insertions"
        );
    }
    assert!(tracked_buckets(&limiter) <= MAX_BUCKETS);
}

/// BH-52: a bucket nobody has touched for the whole TTL is swept, and by then it had refilled anyway.
#[test]
fn an_idle_bucket_is_swept_rather_than_kept_for_ever() {
    let (monotonic, limiter) = manual();
    let idle = Subject::Source("198.51.100.2".parse().expect("idle"));
    assert!(limiter.admit(idle, RateClass::Pairing).is_ok());
    assert_eq!(tracked_buckets(&limiter), 1);
    monotonic.advance(BUCKET_TTL + Duration::from_secs(1));
    let other = Subject::Source("198.51.100.3".parse().expect("other"));
    assert!(limiter.admit(other, RateClass::Pairing).is_ok());
    assert_eq!(
        tracked_buckets(&limiter),
        1,
        "the idle bucket should have been swept when the next one arrived"
    );
}

/// A source that reads elapsed time off the wall clock, which is what BH-53 found in the limiter.
struct WallDerived {
    base: Instant,
    clock: Arc<ManualUtcClock>,
    start: OffsetDateTime,
}

impl Monotonic for WallDerived {
    fn now(&self) -> Instant {
        self.base
            + Duration::from_secs_f64((self.clock.now() - self.start).as_seconds_f64().max(0.0))
    }
}

/// BH-53: the refill delta is monotonic, so a forward wall-clock step refills nothing, while the same limiter reading the wall clock hands the whole burst back at once.
#[test]
fn a_wall_clock_step_refills_nothing() {
    let start = OffsetDateTime::parse("2026-08-28T12:00:00Z", &Rfc3339).expect("instant");
    let wall = Arc::new(ManualUtcClock::new(start));
    let monotonic = Arc::new(ManualMonotonic::default());
    let limiter = RateLimiter::with_monotonic(monotonic.clone());
    let subject = Subject::Device(uuid::Uuid::new_v4());
    drain(&limiter, &subject, RateClass::Pairing);

    wall.advance(time::Duration::hours(6));
    assert!(
        limiter.admit(subject.clone(), RateClass::Pairing).is_err(),
        "a six-hour wall-clock step refilled a bucket"
    );
    monotonic.advance(Duration::from_secs(60));
    assert!(
        limiter.admit(subject.clone(), RateClass::Pairing).is_ok(),
        "a real minute of elapsed time must refill"
    );

    let wall = Arc::new(ManualUtcClock::new(start));
    let wall_limiter = RateLimiter::with_monotonic(Arc::new(WallDerived {
        base: Instant::now(),
        clock: wall.clone(),
        start,
    }));
    drain(&wall_limiter, &subject, RateClass::Pairing);
    wall.advance(time::Duration::hours(6));
    assert!(
        wall_limiter.admit(subject, RateClass::Pairing).is_ok(),
        "this is the defect: reading the wall clock refills the whole burst on a forward step"
    );
}

fn limiter() -> (Arc<ManualMonotonic>, RateLimiter) {
    manual()
}

#[test]
fn a_burst_is_admitted_then_refused_and_refills() {
    let (monotonic, limiter) = limiter();
    let device = Subject::Device(uuid::Uuid::new_v4());
    let (burst, _) = RateClass::Terminal.budget();
    for _ in 0..burst as usize {
        assert!(limiter.admit(device.clone(), RateClass::Terminal).is_ok());
    }
    let retry = limiter
        .admit(device.clone(), RateClass::Terminal)
        .unwrap_err();
    assert!(retry >= 1);

    monotonic.advance(Duration::from_secs(60));
    assert!(
        limiter.admit(device, RateClass::Terminal).is_ok(),
        "a full refill window restores the budget"
    );
}

#[test]
fn budgets_are_per_subject_and_per_class() {
    let (_clock, limiter) = limiter();
    let one = Subject::Device(uuid::Uuid::new_v4());
    let two = Subject::Device(uuid::Uuid::new_v4());
    for _ in 0..10 {
        assert!(limiter.admit(one.clone(), RateClass::Pairing).is_ok());
    }
    assert!(limiter.admit(one.clone(), RateClass::Pairing).is_err());
    assert!(
        limiter.admit(one, RateClass::General).is_ok(),
        "exhausting one class must not close another"
    );
    assert!(
        limiter.admit(two, RateClass::Pairing).is_ok(),
        "one device must not spend another's budget"
    );
}

#[test]
fn classification_matches_the_abuse_shapes_the_plan_names() {
    use axum::http::Method;
    let cases = [
        (Method::POST, "/api/v1/pairing/claim", RateClass::Pairing),
        (
            Method::POST,
            "/api/v1/projects/1/terminals",
            RateClass::Terminal,
        ),
        (
            Method::GET,
            "/api/v1/projects/1/terminals/2/ws",
            RateClass::Terminal,
        ),
        (Method::POST, "/api/v1/projects/1/agents", RateClass::Agent),
        (
            Method::POST,
            "/api/v1/projects/1/changes/2/approve",
            RateClass::Agent,
        ),
        (Method::POST, "/api/v1/builds", RateClass::Build),
        (
            Method::POST,
            "/api/v1/models/acme%2Fm/install",
            RateClass::Model,
        ),
        (Method::GET, "/api/v1/models", RateClass::General),
        (Method::GET, "/api/v1/status", RateClass::General),
        (
            Method::POST,
            "/api/v1/remote/refresh",
            RateClass::RemoteRefresh,
        ),
        (Method::GET, "/api/v1/remote", RateClass::General),
    ];
    for (method, path, expected) in cases {
        assert_eq!(RateClass::classify(&method, path), expected, "{path}");
    }
}

#[test]
fn a_disabled_limiter_admits_everything() {
    let start = OffsetDateTime::parse("2026-08-28T12:00:00Z", &Rfc3339).unwrap();
    let limiter = RateLimiter::disabled(Arc::new(ManualUtcClock::new(start)));
    let device = Subject::Device(uuid::Uuid::new_v4());
    for _ in 0..1_000 {
        assert!(limiter.admit(device.clone(), RateClass::Pairing).is_ok());
    }
}
