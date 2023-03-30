module auctionable_token_objects::common {
    use std::error;
    use aptos_framework::timestamp;
    use aptos_framework::object::{Self, Object};

    const E_NOT_OWNER: u64 = 1;
    const E_PRICE_OUT_OF_RANGE: u64 = 3;
    const E_TIME_EXPIRED: u64 = 4;
    const E_TIME_NOT_EXPIRED: u64 = 5;
    const E_ALREADY_OWNER: u64 = 7;
    const E_INVALID_TIME_RANGE: u64 = 8;

    const MIN_EXPIRATION_SEC: u64 = 86400; // a day
    const MAX_EXPIRATION_SEC: u64 = 2592000; // 30 days

    public fun assert_object_owner<T: key>(obj: Object<T>, owner_addr: address) {
        assert!(object::is_owner<T>(obj, owner_addr), error::permission_denied(E_NOT_OWNER));
    }

    public fun assert_not_object_owner<T: key>(obj: Object<T>, owner_addr: address) {
        assert!(!object::is_owner<T>(obj, owner_addr), error::permission_denied(E_ALREADY_OWNER));
    }

    public fun assert_after_now(sec: u64) {
        assert!(timestamp::now_seconds() < sec, error::invalid_argument(E_TIME_EXPIRED));
    }

    public fun assert_before_now(sec: u64) {
        assert!(sec < timestamp::now_seconds(), error::invalid_argument(E_TIME_NOT_EXPIRED));
    }

    public fun assert_expiration_range(sec: u64) {
        let now = timestamp::now_seconds();
        assert!(
            now + MIN_EXPIRATION_SEC <= sec && sec < now + MAX_EXPIRATION_SEC,
            error::invalid_argument(E_INVALID_TIME_RANGE)
        );
    }

    public fun verify_price_range(price: u64) {
        assert!(
            0 < price && price < 0xffff_ffff_ffff_ffff,
            error::out_of_range(E_PRICE_OUT_OF_RANGE)
        );
    } 
}