module token_objects_marketplace::bids {
    use std::signer;
    use std::error;
    use std::vector;
    use std::option::{Self, Option};
    use aptos_std::table_with_length::{Self, TableWithLength};
    use aptos_framework::timestamp;
    use aptos_framework::coin::{Self, Coin};
    use token_objects::royalty::{Self, Royalty};
    use token_objects_marketplace::common;

    // withdraw after close
    // simple map is enough

    const E_BID_ALREADY: u64 = 1;
    const E_UNEXPECTED_COIN_VALUE: u64 = 2; 

    friend token_objects_marketplace::tradings;

    struct BidId has store, copy, drop {
        bidder_address: address,
        object_address: address,
        index: u64,
        bid_price: u64,
    }

    public fun bidder(bid_id: &BidId): address {
        bid_id.bidder_address
    }

    public fun object_address(bid_id: &BidId): address {
        bid_id.object_address
    }

    public fun bid_price(bid_id: &BidId): u64 {
        bid_id.bid_price
    }

    public fun index(bid_id: &BidId): u64 {
        bid_id.index
    }

    struct Bid<phantom TCoin> has store {
        coin: Coin<TCoin>,
        expiration_sec: u64
    }

    struct BidRecords<phantom TCoin> has key {
        key_list: vector<BidId>,
        bid_table: TableWithLength<BidId, Bid<TCoin>>
    }

    inline fun init_bid_records<TCoin>(bidder: &signer) {
        if (!exists<BidRecords<TCoin>>(signer::address_of(bidder))) {
            move_to(
                bidder,
                BidRecords<TCoin>{
                    key_list: vector::empty(),
                    bid_table: table_with_length::new()
                }
            )
        }
    }

    inline fun calc_royalty(
        value: u64,
        royalty: &Royalty,
    ): u64 {
        let numerator = royalty::numerator(royalty);
        let denominator = royalty::denominator(royalty);
        if (numerator == 0 || denominator == 0) {
            0
        } else {
            value * numerator / denominator
        }
    }

    public fun withdraw_from_expired<TCoin>(bidder: &signer)
    acquires BidRecords {
        let bidder_address = signer::address_of(bidder);
        let records = borrow_global_mut<BidRecords<TCoin>>(bidder_address);

        let coin = coin::zero<TCoin>();
        let now = timestamp::now_seconds();
        let i = 0;
        let len = vector::length(&records.key_list);
        while (i < len) {
            let key = vector::borrow(&records.key_list, i);
            let bid = table_with_length::borrow_mut(&mut records.bid_table, *key);
            if (
                bid.expiration_sec <= now &&
                coin::value(&bid.coin) > 0
            ) {
                coin::merge(&mut coin, coin::extract_all(&mut bid.coin))
            };
            i = i + 1;  
        };
        coin::deposit(bidder_address, coin);
    }

    public(friend) fun bid<TCoin>(
        bidder: &signer,
        object_address: address,
        index: u64,
        expiration_sec: u64,
        bid_price: u64
    ): BidId
    acquires BidRecords {
        common::assert_after_now(expiration_sec);
        common::verify_price_range(bid_price);
        let bidder_address = signer::address_of(bidder);
        init_bid_records<TCoin>(bidder);
        let records = borrow_global_mut<BidRecords<TCoin>>(bidder_address);
        let bid_id = BidId {
            bidder_address,
            object_address,
            index,
            bid_price
        };
        assert!(
            !table_with_length::contains(&records.bid_table, bid_id),
            error::already_exists(E_BID_ALREADY)
        );
        
        let coin = coin::withdraw<TCoin>(bidder, bid_price);
        vector::push_back(&mut records.key_list, bid_id);
        table_with_length::add(
            &mut records.bid_table, 
            bid_id, Bid{
                coin,
                expiration_sec
            }
        );
        bid_id
    }

    public(friend) fun execute_bid<TCoin>(
        bid_id: BidId,
        royalty: Option<Royalty>
    ): Coin<TCoin>
    acquires BidRecords {
        let records = borrow_global_mut<BidRecords<TCoin>>(bid_id.bidder_address);
        let bid = table_with_length::borrow_mut(&mut records.bid_table, bid_id);
        let stored_coin = coin::extract_all(&mut bid.coin);
        let stored_value = coin::value(&stored_coin);
        assert!(bid_id.bid_price == stored_value, error::internal(E_UNEXPECTED_COIN_VALUE));
        assert!(coin::value(&stored_coin) > 0, error::resource_exhausted(E_UNEXPECTED_COIN_VALUE));

        if (option::is_some(&royalty)) {
            let royalty_extracted = option::destroy_some(royalty);
            let royalty_addr = royalty::payee_address(&royalty_extracted);
            let royalty_value = calc_royalty(stored_value, &royalty_extracted);
            let royalty_coin = coin::extract(&mut stored_coin, royalty_value);
            coin::deposit(royalty_addr, royalty_coin)
        };
        stored_coin
    }

    #[test_only]
    use aptos_framework::account;
    #[test_only]
    use aptos_framework::coin::FakeMoney;

    #[test_only]
    fun setup_test(bidder: &signer, other: &signer, framework: &signer) {
        account::create_account_for_test(@0x1);
        account::create_account_for_test(signer::address_of(bidder));
        account::create_account_for_test(signer::address_of(other));
        timestamp::set_time_has_started_for_testing(framework);
    }

    #[test_only]
    fun create_test_money(bidder: &signer, other: &signer, framework: &signer) {
        coin::create_fake_money(framework, bidder, 200);
        coin::register<FakeMoney>(bidder);
        coin::register<FakeMoney>(other);
        coin::transfer<FakeMoney>(framework, signer::address_of(bidder), 100);
        coin::transfer<FakeMoney>(framework, signer::address_of(other), 100);
    }

    #[test(bidder = @0x123, other = @234, framework = @0x1)]
    fun test_bid(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let bidder_address = signer::address_of(bidder);
        let object_address = @0x0b1;
        bid<FakeMoney>(bidder, object_address, 0, 1, 1);
        let records = borrow_global<BidRecords<FakeMoney>>(bidder_address);
        assert!(vector::length(&records.key_list) == 1, 0);
        assert!(table_with_length::contains(&records.bid_table, BidId{
            bidder_address,
            object_address,
            index: 0,
            bid_price: 1
        }), 1);
    }

    #[test(bidder = @0x123, other = @234, framework = @0x1)]
    #[expected_failure(abort_code = 524289, location = Self)]
    fun test_fail_bid_twice(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let object_address = @0x0b1;
        bid<FakeMoney>(bidder, object_address, 0, 1, 1);
        bid<FakeMoney>(bidder, object_address, 0, 1, 1);
    }

    #[test(bidder = @0x123, other = @234, framework = @0x1)]
    #[expected_failure(abort_code = 65542, location = aptos_framework::coin)]
    fun test_fail_bid_too_big(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let object_address = @0x0b1;
        bid<FakeMoney>(bidder, object_address, 0, 1, 101);
    }

    #[test(bidder = @0x123, other = @234, framework = @0x1)]
    #[expected_failure(abort_code = 65540, location = token_objects_marketplace::common)]
    fun test_fail_bid_wrong_expiration(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);
        timestamp::update_global_time_for_test(2000_000);

        let object_address = @0x0b1;
        bid<FakeMoney>(bidder, object_address, 0, 1, 1);
    }

    #[test(bidder = @0x123, other = @234, framework = @0x1)]
    #[expected_failure(abort_code = 131075, location = token_objects_marketplace::common)]
    fun test_fail_bid_zero(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let object_address = @0x0b1;
        bid<FakeMoney>(bidder, object_address, 0, 1, 0);
    }

    #[test(bidder = @0x123, other = @234, framework = @0x1)]
    #[expected_failure(abort_code = 131075, location = token_objects_marketplace::common)]
    fun test_fail_bid_max(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let object_address = @0x0b1;
        bid<FakeMoney>(bidder, object_address, 0, 1, 0xffffffff_ffffffff);
    }

    #[test(bidder = @0x123, other = @234, framework = @0x1)]
    fun test_execute(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let other_address = signer::address_of(other);
        let bidder_address = signer::address_of(bidder);
        let object_address = @0x0b1;
        let bid_id = bid<FakeMoney>(bidder, object_address, 0, 1, 100);
        
        let royalty = option::some(royalty::create(10, 100, other_address));
        let coin = execute_bid<FakeMoney>(bid_id, royalty);
        assert!(coin::balance<FakeMoney>(bidder_address) == 0, 0);
        assert!(coin::balance<FakeMoney>(other_address) == 110, 1);
        assert!(coin::value(&coin) == 90, 2);
        coin::deposit(other_address, coin);
        assert!(coin::balance<FakeMoney>(other_address) == 200, 3);
    }

    #[test(bidder = @0x123, other = @234, framework = @0x1)]
    fun test_execute2(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let other_address = signer::address_of(other);
        let bidder_address = signer::address_of(bidder);
        let object_address = @0x0b1;
        let bid_id = bid<FakeMoney>(bidder, object_address, 0, 1, 100);
        
        //let royalty = option::some(royalty::create(0, 100, other_address));
        let coin = execute_bid<FakeMoney>(bid_id, option::none());
        assert!(coin::balance<FakeMoney>(bidder_address) == 0, 0);
        assert!(coin::balance<FakeMoney>(other_address) == 100, 1);
        assert!(coin::value(&coin) == 100, 2);
        coin::deposit(other_address, coin);
        assert!(coin::balance<FakeMoney>(other_address) == 200, 3);
    }

    #[test(bidder = @0x123, other = @234, framework = @0x1)]
    #[expected_failure]
    fun test_execute_fail_wrong_bid_id(bidder: &signer, other: &signer, framework: &signer)
    acquires BidRecords {
        setup_test(bidder, other, framework);
        create_test_money(bidder, other, framework);

        let other_address = signer::address_of(other);
        let object_address = @0x0b1;
        let bid_id = bid<FakeMoney>(bidder, object_address, 0, 1, 100);
        bid_id.object_address = @777;

        let royalty = option::some(royalty::create(10, 100, other_address));
        let coin = execute_bid<FakeMoney>(bid_id, royalty);
        coin::deposit(other_address, coin);
    }
}