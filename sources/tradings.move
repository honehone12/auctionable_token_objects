module token_objects_marketplace::tradings {
    use std::signer;
    use std::error;
    use std::vector;
    use std::string::String;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::table_with_length::{Self, TableWithLength};
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use token_objects::royalty;
    use token_objects_marketplace::common;
    use token_objects_marketplace::bids::{Self, BidId};

    const E_ALREADY_ACTIVE: u64 = 1;
    const E_NOT_ACTIVE: u64 = 2;
    const E_PRICE_TOO_LOW: u64 = 3;
    const E_EMPTY_COIN: u64 = 4;
    const E_ALREADY_SOLD: u64 = 5;

    const MAX_WAIT_UNTIL_EXECUTION: u64 = 86400; // a day

    struct Trading<phantom TCoin> has store {
        min_price: u64,
        is_instant_sale: bool,
        expiration_sec: u64,

        bid_map: SimpleMap<u64, BidId>,
        bid_prices: vector<u64>
    }

    struct TradingRecords<phantom TCoin> has key {
        index: u64,
        trading_table: TableWithLength<u64, Trading<TCoin>>,
        has_active: bool
    }
    
    inline fun highest_price<TCoin>(trading: &Trading<TCoin>): u64 {
        let len = vector::length(&trading.bid_prices);
        if (len == 0) {
            trading.min_price
        } else {
            *vector::borrow(&trading.bid_prices, len -1)
        }
    }

    public fun init_with_extend_ref<T: key, TCoin>(
        extend_ref: &ExtendRef,
        object: Object<T>,
        collection_name: String,
        token_name: String
    ) {
        common::verify_token_object<T>(object, collection_name, token_name);
        let token_signer = object::generate_signer_for_extending(extend_ref);
        move_to(
            &token_signer,
            TradingRecords<TCoin>{
                index: 0,
                trading_table: table_with_length::new(),
                has_active: false
            }
        )
    }

    public fun start_trading<T: key, TCoin>(
        owner: &signer,
        object: Object<T>,
        collection_name: String,
        token_name: String,
        is_instant_sale: bool,
        expiration_sec: u64,
        min_price: u64
    ): u64
    acquires TradingRecords {
        let owner_addr = signer::address_of(owner);
        common::assert_object_owner<T>(object, owner_addr);
        common::verify_token_object<T>(object, collection_name, token_name);
        common::verify_price_range(min_price);
        common::assert_expiration_range(expiration_sec);
        let obj_addr = object::object_address(&object);
        let records = borrow_global_mut<TradingRecords<TCoin>>(obj_addr);
        assert!(!records.has_active, error::already_exists(E_ALREADY_ACTIVE));
        let idx = records.index;
        table_with_length::add(
            &mut records.trading_table,
            idx, Trading{
                min_price,
                is_instant_sale,
                expiration_sec,
                bid_map: simple_map::create(),
                bid_prices: vector::empty()
            }
        );
        records.index = idx + 1;
        records.has_active = true;
        idx
    }

    public fun bid<T: key, TCoin>(
        bidder: &signer,
        object_address: address,
        index: u64,
        bid_price: u64
    )
    acquires TradingRecords {
        let bidder_addr = signer::address_of(bidder); 
        common::assert_enough_balance<TCoin>(bidder_addr, bid_price);
        let obj = object::address_to_object<T>(object_address);
        common::assert_not_object_owner(obj, bidder_addr);
        let records = borrow_global_mut<TradingRecords<TCoin>>(object_address);
        assert!(records.has_active, error::unavailable(E_NOT_ACTIVE));
        let trading = table_with_length::borrow_mut(&mut records.trading_table, index);
        common::assert_after_now(trading.expiration_sec);
        let bid_id = bids::bid<TCoin>(
            bidder,
            object_address,
            index,
            trading.expiration_sec + MAX_WAIT_UNTIL_EXECUTION,
            bid_price
        );

        if (trading.is_instant_sale) {
            assert!(bid_price >= trading.min_price, error::invalid_argument(E_PRICE_TOO_LOW));
            assert!(vector::length(&trading.bid_prices) == 0, error::unavailable(E_ALREADY_SOLD));
        } else {
            assert!(bid_price > highest_price(trading), error::invalid_argument(E_PRICE_TOO_LOW));
        };
        
        vector::push_back(&mut trading.bid_prices, bid_price);
        simple_map::add(&mut trading.bid_map, bid_price, bid_id);
    }

    public fun complete<T: key, TCoin>(
        owner: &signer,
        object_address: address,
        index: u64,
    )
    acquires TradingRecords {
        let owner_address = signer::address_of(owner);
        let obj = object::address_to_object<T>(object_address);
        common::assert_object_owner(obj, owner_address);
        let records = borrow_global_mut<TradingRecords<TCoin>>(object_address);
        assert!(records.has_active, error::unavailable(E_NOT_ACTIVE));
        let trading = table_with_length::borrow_mut(&mut records.trading_table, index);
        common::assert_before_now(trading.expiration_sec);
        
        if (
            vector::length(&trading.bid_prices) > 0 && 
            timestamp::now_seconds() < trading.expiration_sec + MAX_WAIT_UNTIL_EXECUTION  
        ) {
            let highest_price = highest_price(trading);
            let bid_id = simple_map::borrow(&trading.bid_map, &highest_price);
            let royalty = royalty::get(obj);
            let coin = bids::execute_bid<TCoin>(*bid_id, royalty);
            assert!(coin::value(&coin) > 0, error::resource_exhausted(E_EMPTY_COIN));
            records.has_active = false;
            object::transfer(owner, obj, bids::bidder(bid_id));
            coin::deposit(owner_address, coin);
        } else {
            records.has_active = false;
        }
    }

    #[test_only]
    use std::option;
    #[test_only]
    use std::string::utf8;
    #[test_only]
    use aptos_framework::coin::FakeMoney;
    #[test_only]
    use aptos_framework::object::ConstructorRef;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use token_objects::token;
    #[test_only]
    use token_objects::collection;

    #[test_only]
    struct FreePizzaPass has key {}

    #[test_only]
    fun setup_test(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
    }

    #[test_only]
    fun setup_test_plus(creator: &signer, bidder: &signer, framework: &signer) {
        account::create_account_for_test(@0x1);
        account::create_account_for_test(signer::address_of(creator));
        account::create_account_for_test(signer::address_of(bidder));
        timestamp::set_time_has_started_for_testing(framework);
    }

    #[test_only]
    fun create_test_money(creator: &signer, bidder: &signer, framework: &signer) {
        coin::create_fake_money(framework, bidder, 200);
        coin::register<FakeMoney>(creator);
        coin::register<FakeMoney>(bidder);
        coin::transfer<FakeMoney>(framework, signer::address_of(creator), 100);
        coin::transfer<FakeMoney>(framework, signer::address_of(bidder), 100);
    }

    #[test_only]
    fun create_test_object(creator: &signer): ConstructorRef {
        _ = collection::create_untracked_collection(
            creator,
            utf8(b"collection description"),
            utf8(b"collection"),
            option::none(),
            utf8(b"collection uri"),
        );
        let cctor = token::create(
            creator,
            utf8(b"collection"),
            utf8(b"description"),
            utf8(b"name"),
            option::some(royalty::create(10, 100, signer::address_of(creator))),
            utf8(b"uri")
        );
        move_to(&object::generate_signer(&cctor), FreePizzaPass{});
        cctor
    }

    #[test(creator = @0x123)]
    fun test_init(creator: &signer) {
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let obj_addr = object::object_address(&obj);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        assert!(exists<TradingRecords<FakeMoney>>(obj_addr), 0);
    }

    #[test(creator = @0x123)]
    #[expected_failure(abort_code = 65538, location = token_objects_marketplace::common)]
    fun test_init_fail_wrong_collection(creator: &signer) {
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"bad-collection"), utf8(b"name"));
    }

    #[test(creator = @0x123)]
    #[expected_failure(abort_code = 65538, location = token_objects_marketplace::common)]
    fun test_init_fail_wrong_name(creator: &signer) {
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"bad-name"));
    }

    #[test(creator = @0x123, framework = @0x1)]
    fun test_start_trading(creator: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let obj_addr = object::object_address(&obj);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            1
        );
        let records = borrow_global<TradingRecords<FakeMoney>>(obj_addr);
        assert!(records.index == 1, 0);
        assert!(records.has_active, 1);
        assert!(table_with_length::contains(&records.trading_table, 0), 2);
        let auction = table_with_length::borrow(&records.trading_table, 0);
        assert!(auction.expiration_sec == 86401, 3);
        assert!(auction.min_price == 1, 3);
        assert!(!auction.is_instant_sale, 4);
    }

    #[test(creator = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 327681, location = token_objects_marketplace::common)]
    fun test_start_trading_fail_not_owner(creator: &signer, other: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            other,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            1
        );
    }

    #[test(creator = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = 65538, location = token_objects_marketplace::common)]
    fun test_start_trading_fail_wrong_collection(creator: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"bad-collection"), utf8(b"name"),
            false,
            1 + 86400,
            1
        );
    }

    #[test(creator = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = 65538, location = token_objects_marketplace::common)]
    fun test_start_trading_fail_wrong_name(creator: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"bad-name"),
            false,
            1 + 86400,
            1
        );
    }

    #[test(creator = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = 131075, location = token_objects_marketplace::common)]
    fun test_start_trading_fail_price_zero(creator: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            0
        );
    }

    #[test(creator = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = 131075, location = token_objects_marketplace::common)]
    fun test_start_trading_fail_price_max(creator: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            0xffffffff_ffffffff
        );
    }

    #[test(creator = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = 65544, location = token_objects_marketplace::common)]
    fun test_start_trading_fail_expire_in_past(creator: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test(framework);
        timestamp::update_global_time_for_test(20_000_000 + 86400_000_000);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1  + 86400,
            1
        );
    }

    #[test(creator = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = 524289, location = Self)]
    fun test_start_trading_fail_start_twice(creator: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            1
        );

        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            2 + 86400,
            2
        );
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    fun test_bid(creator: &signer, bidder: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        let index = 0;
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            index,
            20
        );

        let records = borrow_global<TradingRecords<FakeMoney>>(object_address);
        let trading = table_with_length::borrow(&records.trading_table, index);
        assert!(vector::length(&trading.bid_prices) == 1, 0);
        assert!(simple_map::contains_key(&trading.bid_map, &20), 1);
        assert!(coin::balance<FakeMoney>(signer::address_of(bidder)) == 80, 2);
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65539, location = Self)]
    fun test_fail_bid_too_low(creator: &signer, bidder: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        let index = 0;
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            index,
            5
        );
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 327687, location = token_objects_marketplace::common)]
    fun test_fail_bid_owner(creator: &signer, bidder: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1  + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        let index = 0;
        bid<FreePizzaPass, FakeMoney>(
            creator,
            object_address,
            index,
            20
        );
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 196614, location = token_objects_marketplace::common)]
    fun test_fail_bid_too_high(creator: &signer, bidder: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        let index = 0;
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            index,
            200
        );
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65540, location = token_objects_marketplace::common)]
    fun test_fail_bid_expired(creator: &signer, bidder: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            10
        );

        timestamp::update_global_time_for_test(2_000_000 + 86400_000_000);

        let object_address = object::object_address(&obj);
        let index = 0;
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            index,
            20
        );
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 524289, location = token_objects_marketplace::bids)]
    fun test_fail_bid_same_price(creator: &signer, bidder: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        let index = 0;
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            index,
            20
        );

        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            index,
            20
        );
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 851973, location = Self)]
    fun test_fail_bid_after_instant_sale(creator: &signer, bidder: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            true,
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        let index = 0;
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            index,
            20
        );

        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            index,
            30
        );
    }
    
    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    fun test_complete(creator: &signer, bidder: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        let index = start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            index,
            20
        );

        timestamp::update_global_time_for_test(2_000_000 + 86400_000_000);
        complete<FreePizzaPass, FakeMoney>(creator, object_address, index);

        let records = borrow_global<TradingRecords<FakeMoney>>(object_address);
        assert!(!records.has_active, 1);
        assert!(coin::balance<FakeMoney>(@0x123) == 120, 2);
        assert!(coin::balance<FakeMoney>(@0x234) == 80, 2);
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 327681, location = token_objects_marketplace::common)]
    fun test_complete_fail_not_owner(creator: &signer, bidder: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        let index = start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            index,
            20
        );

        timestamp::update_global_time_for_test(2_000_000);
        complete<FreePizzaPass, FakeMoney>(bidder, object_address, index);
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65541, location = token_objects_marketplace::common)]
    fun test_complete_fail_before_expiration(creator: &signer, bidder: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        let index = start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            index,
            20
        );

        complete<FreePizzaPass, FakeMoney>(creator, object_address, index);
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 851970, location = Self)]
    fun test_complete_fail_not_started(creator: &signer, bidder: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));

        let object_address = object::object_address(&obj);

        timestamp::update_global_time_for_test(2_000_000);
        complete<FreePizzaPass, FakeMoney>(creator, object_address, 0);
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure]
    fun test_complete_fail_wrong_obj(creator: &signer, bidder: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        let index = start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            index,
            20
        );

        timestamp::update_global_time_for_test(2_000_000);
        complete<FreePizzaPass, FakeMoney>(creator, @0x0b1, index);
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure]
    fun test_complete_fail_wrong_idx(creator: &signer, bidder: &signer, framework: &signer)
    acquires TradingRecords {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_with_extend_ref<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        let index = start_trading<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            false,
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            index,
            20
        );

        timestamp::update_global_time_for_test(2_000_000);
        complete<FreePizzaPass, FakeMoney>(creator, object_address, 1);
    }
}