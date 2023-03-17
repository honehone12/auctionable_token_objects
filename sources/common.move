module token_objects_marketplace::common {
    use std::error;
    use std::string::String;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::timestamp;
    use token_objects::token;

    const E_NOT_OWNER: u64 = 1;
    const E_INCONSISTENT_NAME: u64 = 2;
    const E_PRICE_OUT_OF_RANGE: u64 = 3;
    const E_TIME_OF_PAST: u64 = 4;
    const E_TIME_OF_FUTURE: u64 = 5;

    public fun assert_object_owner<T: key>(obj: Object<T>, owner_addr: address) {
        assert!(object::is_owner<T>(obj, owner_addr), error::permission_denied(E_NOT_OWNER));
    }

    public fun assert_after_now(sec: u64) {
        assert!(timestamp::now_seconds() < sec, error::invalid_argument(E_TIME_OF_PAST));
    }

    public fun assert_before_now(sec: u64) {
        assert!(sec < timestamp::now_seconds(), error::invalid_argument(E_TIME_OF_FUTURE));
    }

    public fun verify_token_object<T: key>(
        obj: Object<T>, 
        collecttion_name: String,
        token_name: String
    ) {
        assert!(
            token::collection(obj) == collecttion_name &&
            token::name(obj) == token_name,
            error::invalid_argument(E_INCONSISTENT_NAME)
        );
    }

    public fun verify_price_range(price: u64) {
        assert!(
            0 < price && price < 0xffff_ffff_ffff_ffff,
            error::out_of_range(E_PRICE_OUT_OF_RANGE)
        );
    } 
}