module auctionable_token_objects::auctions {
    use std::signer;
    use std::error;
    use std::vector;
    use std::string::String;
    use std::option::{Self, Option};
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_token_objects::royalty;
    use auctionable_token_objects::common;
    use auctionable_token_objects::bids::{Self, BidId};

    const E_ALREADY_ACTIVE: u64 = 1;
    const E_NOT_ACTIVE: u64 = 2;
    const E_PRICE_TOO_LOW: u64 = 3;
    const E_EMPTY_COIN: u64 = 4;
    const E_ALREADY_SOLD: u64 = 5;
    const E_OWNER_CHANGED: u64 = 6;

    const MAX_WAIT_UNTIL_EXECUTION: u64 = 86400; // a day

    #[resource_group_member(group = object::ObjectGroup)]
    struct Auction<phantom TCoin> has key {
        lister: Option<address>,
        min_price: u64,
        expiration_sec: u64,

        bid_map: SimpleMap<u64, BidId>,
        bid_prices: vector<u64>
    }
    
    inline fun highest_price<TCoin>(auction: &Auction<TCoin>): u64 {
        let len = vector::length(&auction.bid_prices);
        if (len == 0) {
            auction.min_price
        } else {
            *vector::borrow(&auction.bid_prices, len -1)
        }
    }

    public fun init_for_coin_type<T: key, TCoin>(
        extend_ref: &ExtendRef,
        object: Object<T>,
        collection_name: String,
        token_name: String
    ) {
        common::verify_token_object<T>(object, collection_name, token_name);
        let token_signer = object::generate_signer_for_extending(extend_ref);
        move_to(
            &token_signer,
            Auction<TCoin>{
                lister: option::none(),
                min_price: 0,
                expiration_sec: 0,
                bid_map: simple_map::create(),
                bid_prices: vector::empty()
            }
        )
    }

    public fun start_auction<T: key, TCoin>(
        owner: &signer,
        object: Object<T>,
        collection_name: String,
        token_name: String,
        expiration_sec: u64,
        min_price: u64
    )
    acquires Auction {
        let owner_addr = signer::address_of(owner);
        common::assert_object_owner<T>(object, owner_addr);
        common::verify_token_object<T>(object, collection_name, token_name);
        common::verify_price_range(min_price);
        common::assert_expiration_range(expiration_sec);
        let obj_addr = object::object_address(&object);
        let auction = borrow_global_mut<Auction<TCoin>>(obj_addr);
        assert!(option::is_none(&auction.lister), error::already_exists(E_ALREADY_ACTIVE));
        
        auction.min_price = min_price;
        auction.expiration_sec = expiration_sec;
        auction.lister = option::some(owner_addr);
    }

    public fun bid<T: key, TCoin>(
        bidder: &signer,
        object_address: address,
        bid_price: u64
    )
    acquires Auction {
        let bidder_addr = signer::address_of(bidder); 
        common::assert_enough_balance<TCoin>(bidder_addr, bid_price);
        let obj = object::address_to_object<T>(object_address);
        common::assert_not_object_owner(obj, bidder_addr);
        let auction = borrow_global_mut<Auction<TCoin>>(object_address);
        assert!(option::is_some(&auction.lister), error::unavailable(E_NOT_ACTIVE));
        common::assert_after_now(auction.expiration_sec);
        assert!(bid_price > highest_price(auction), error::invalid_argument(E_PRICE_TOO_LOW));
        let bid_id = bids::bid<TCoin>(
            bidder,
            object_address,
            auction.expiration_sec + MAX_WAIT_UNTIL_EXECUTION,
            bid_price
        );

        vector::push_back(&mut auction.bid_prices, bid_price);
        simple_map::add(&mut auction.bid_map, bid_price, bid_id);
    }

    public fun complete<T: key, TCoin>(
        owner: &signer,
        object_address: address
    )
    acquires Auction {
        let owner_addr = signer::address_of(owner);
        let obj = object::address_to_object<T>(object_address);
        common::assert_object_owner(obj, owner_addr);
        let auction = borrow_global_mut<Auction<TCoin>>(object_address);
        assert!(option::is_some(&auction.lister), error::unavailable(E_NOT_ACTIVE));
        common::assert_before_now(auction.expiration_sec);
        let highest_price = highest_price(auction);
        let bid_id = *simple_map::borrow(&auction.bid_map, &highest_price);
        let deadline = auction.expiration_sec + MAX_WAIT_UNTIL_EXECUTION;
        let lister = option::extract(&mut auction.lister);
        
        auction.min_price = 0;
        auction.expiration_sec = 0;

        if (vector::length(&auction.bid_prices) > 0) {
            auction.bid_prices = vector::empty();
            auction.bid_map = simple_map::create();

            if (timestamp::now_seconds() < deadline) {
                assert!(lister == owner_addr, error::internal(E_OWNER_CHANGED));
                let royalty = royalty::get(obj);
                let coin = bids::execute_bid<TCoin>(bid_id, royalty);
                assert!(coin::value(&coin) > 0, error::resource_exhausted(E_EMPTY_COIN));
                object::transfer(owner, obj, bids::bidder(&bid_id));
                coin::deposit(owner_addr, coin);
            };
        };
    }

    #[test_only]
    use std::string::utf8;
    #[test_only]
    use aptos_framework::coin::FakeMoney;
    #[test_only]
    use aptos_framework::object::ConstructorRef;
    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_token_objects::token;
    #[test_only]
    use aptos_token_objects::collection;

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
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        assert!(exists<Auction<FakeMoney>>(obj_addr), 0);
    }

    #[test(creator = @0x123)]
    #[expected_failure(abort_code = 65538, location = auctionable_token_objects::common)]
    fun test_init_fail_wrong_collection(creator: &signer) {
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"bad-collection"), utf8(b"name"));
    }

    #[test(creator = @0x123)]
    #[expected_failure(abort_code = 65538, location = auctionable_token_objects::common)]
    fun test_init_fail_wrong_name(creator: &signer) {
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"bad-name"));
    }

    #[test(creator = @0x123, framework = @0x1)]
    fun test_start_auction(creator: &signer, framework: &signer)
    acquires Auction {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let obj_addr = object::object_address(&obj);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            1
        );
        let auction = borrow_global<Auction<FakeMoney>>(obj_addr);
        assert!(auction.lister == option::some(@0x123), 1);
        assert!(auction.expiration_sec == 86401, 3);
        assert!(auction.min_price == 1, 3);
    }

    #[test(creator = @0x123, other = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 327681, location = auctionable_token_objects::common)]
    fun test_start_auction_fail_not_owner(creator: &signer, other: &signer, framework: &signer)
    acquires Auction {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            other,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            1
        );
    }

    #[test(creator = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = 65538, location = auctionable_token_objects::common)]
    fun test_start_auction_fail_wrong_collection(creator: &signer, framework: &signer)
    acquires Auction {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"bad-collection"), utf8(b"name"),
            1 + 86400,
            1
        );
    }

    #[test(creator = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = 65538, location = auctionable_token_objects::common)]
    fun test_start_auction_fail_wrong_name(creator: &signer, framework: &signer)
    acquires Auction {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"bad-name"),
            1 + 86400,
            1
        );
    }

    #[test(creator = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = 131075, location = auctionable_token_objects::common)]
    fun test_start_auction_fail_price_zero(creator: &signer, framework: &signer)
    acquires Auction {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            0
        );
    }

    #[test(creator = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = 131075, location = auctionable_token_objects::common)]
    fun test_start_auction_fail_price_max(creator: &signer, framework: &signer)
    acquires Auction {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            0xffffffff_ffffffff
        );
    }

    #[test(creator = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = 65544, location = auctionable_token_objects::common)]
    fun test_start_auction_fail_expire_in_past(creator: &signer, framework: &signer)
    acquires Auction {
        setup_test(framework);
        timestamp::update_global_time_for_test(20_000_000 + 86400_000_000);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1  + 86400,
            1
        );
    }

    #[test(creator = @0x123, framework = @0x1)]
    #[expected_failure(abort_code = 524289, location = Self)]
    fun test_start_auction_fail_start_twice(creator: &signer, framework: &signer)
    acquires Auction {
        setup_test(framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            1
        );

        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            2 + 86400,
            2
        );
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    fun test_bid(creator: &signer, bidder: &signer, framework: &signer)
    acquires Auction {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            20
        );

        let auction = borrow_global<Auction<FakeMoney>>(object_address);
        assert!(vector::length(&auction.bid_prices) == 1, 0);
        assert!(simple_map::contains_key(&auction.bid_map, &20), 1);
        assert!(coin::balance<FakeMoney>(signer::address_of(bidder)) == 80, 2);
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65539, location = Self)]
    fun test_fail_bid_too_low(creator: &signer, bidder: &signer, framework: &signer)
    acquires Auction {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            5
        );
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 327687, location = auctionable_token_objects::common)]
    fun test_fail_bid_owner(creator: &signer, bidder: &signer, framework: &signer)
    acquires Auction {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1  + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            creator,
            object_address,
            20
        );
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 196614, location = auctionable_token_objects::common)]
    fun test_fail_bid_too_high(creator: &signer, bidder: &signer, framework: &signer)
    acquires Auction {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            200
        );
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65540, location = auctionable_token_objects::common)]
    fun test_fail_bid_expired(creator: &signer, bidder: &signer, framework: &signer)
    acquires Auction {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            10
        );

        timestamp::update_global_time_for_test(2_000_000 + 86400_000_000);

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            20
        );
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65539, location = Self)]
    fun test_fail_bid_same_price(creator: &signer, bidder: &signer, framework: &signer)
    acquires Auction {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            20
        );

        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            20
        );
    }
    
    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    fun test_complete(creator: &signer, bidder: &signer, framework: &signer)
    acquires Auction {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            20
        );

        timestamp::update_global_time_for_test(2_000_000 + 86400_000_000);
        complete<FreePizzaPass, FakeMoney>(creator, object_address);

        let auction = borrow_global<Auction<FakeMoney>>(object_address);
        assert!(coin::balance<FakeMoney>(@0x123) == 120, 2);
        assert!(coin::balance<FakeMoney>(@0x234) == 80, 3);

        assert!(auction.min_price == 0, 4);
        assert!(option::is_none(&auction.lister), 5);
        assert!(auction.expiration_sec == 0, 6);
        assert!(simple_map::length(&auction.bid_map) == 0, 7);
        assert!(vector::length(&auction.bid_prices) == 0, 8);
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 327681, location = auctionable_token_objects::common)]
    fun test_complete_fail_not_owner(creator: &signer, bidder: &signer, framework: &signer)
    acquires Auction {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            20
        );

        timestamp::update_global_time_for_test(2_000_000);
        complete<FreePizzaPass, FakeMoney>(bidder, object_address);
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 65541, location = auctionable_token_objects::common)]
    fun test_complete_fail_before_expiration(creator: &signer, bidder: &signer, framework: &signer)
    acquires Auction {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            20
        );

        complete<FreePizzaPass, FakeMoney>(creator, object_address);
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure(abort_code = 851970, location = Self)]
    fun test_complete_fail_not_started(creator: &signer, bidder: &signer, framework: &signer)
    acquires Auction {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));

        let object_address = object::object_address(&obj);

        timestamp::update_global_time_for_test(2_000_000);
        complete<FreePizzaPass, FakeMoney>(creator, object_address);
    }

    #[test(creator = @0x123, bidder = @0x234, framework = @0x1)]
    #[expected_failure]
    fun test_complete_fail_wrong_obj(creator: &signer, bidder: &signer, framework: &signer)
    acquires Auction {
        setup_test_plus(creator, bidder, framework);
        create_test_money(creator, bidder, framework);
        let cctor = create_test_object(creator);
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor);
        let ex = object::generate_extend_ref(&cctor);
        init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        start_auction<FreePizzaPass, FakeMoney>(
            creator,
            obj,
            utf8(b"collection"), utf8(b"name"),
            1 + 86400,
            10
        );

        let object_address = object::object_address(&obj);
        bid<FreePizzaPass, FakeMoney>(
            bidder,
            object_address,
            20
        );

        timestamp::update_global_time_for_test(2_000_000);
        complete<FreePizzaPass, FakeMoney>(creator, @0x0b1);
    }
}