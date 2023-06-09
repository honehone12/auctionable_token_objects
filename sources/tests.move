#[test_only]
module auctionable_token_objects::tests {
    use std::signer;
    use std::option;
    use std::string::utf8;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use aptos_framework::coin::{Self, FakeMoney};
    use aptos_framework::object::{Self, Object};
    use aptos_token_objects::collection;
    use aptos_token_objects::token;
    use aptos_token_objects::royalty;
    use auctionable_token_objects::auctions;
    use auctionable_token_objects::bids;
    use components_common::components_common::{Self, TransferKey};
    use components_common::token_objects_store;

    struct FreePizzaPass has key {}

    fun setup_test(
        owner: &signer, 
        bidder_1: &signer, 
        bidder_2: &signer, 
        creator: &signer, 
        framework: &signer
    ) {
        account::create_account_for_test(@0x1);
        timestamp::set_time_has_started_for_testing(framework);
        account::create_account_for_test(@0x123);
        account::create_account_for_test(@0x234);
        account::create_account_for_test(@0x345);
        account::create_account_for_test(@0x456);
        coin::register<FakeMoney>(owner);
        coin::register<FakeMoney>(bidder_1);
        coin::register<FakeMoney>(bidder_2);
        coin::register<FakeMoney>(creator);
        coin::create_fake_money(framework, creator, 400);
        coin::transfer<FakeMoney>(framework, @0x123, 100);
        coin::transfer<FakeMoney>(framework, @0x234, 100);
        coin::transfer<FakeMoney>(framework, @0x345, 100);
        coin::transfer<FakeMoney>(framework, @0x456, 100);
        token_objects_store::register(owner);
        token_objects_store::register(bidder_1);
        token_objects_store::register(bidder_2);
        token_objects_store::register(creator);
    }

    fun create_test_object(creator: &signer): (Object<FreePizzaPass>, TransferKey) {
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
        let obj = object::object_from_constructor_ref<FreePizzaPass>(&cctor); 
        let ex = object::generate_extend_ref(&cctor);
        let key = components_common::create_transfer_key(cctor);
        auctions::init_for_coin_type<FreePizzaPass, FakeMoney>(&ex, obj, utf8(b"collection"), utf8(b"name"));
        (obj, key)
    }

    #[test(
        owner = @0x123, 
        bidder_1 = @0x234, 
        bidder_2 = @0x345,  
        creator = @0x456,
        framework = @0x1
    )]
    fun test_auction_happy_path(
        owner: &signer, 
        bidder_1: &signer, 
        bidder_2: &signer,
        creator: &signer, 
        framework: &signer
    ){
        setup_test(owner, bidder_1, bidder_2, creator, framework);
        let (obj, key) = create_test_object(creator);
        object::transfer(creator, obj, @0x123);
        components_common::disable_transfer(&mut key);
        auctions::start_auction<FreePizzaPass, FakeMoney>(
            owner,
            key,
            obj, 
            86400 + 5,
            10
        );

        auctions::bid<FreePizzaPass, FakeMoney>(
            bidder_1,
            obj,
            15
        );

        auctions::bid<FreePizzaPass, FakeMoney>(
            bidder_2,
            obj,
            20
        );

        timestamp::update_global_time_for_test(6_000_000 + 86400_000_000);
        let ret = auctions::complete<FreePizzaPass, FakeMoney>(
            owner,
            obj
        );

        assert!(coin::balance<FakeMoney>(@0x123) == 118, 0);
        assert!(coin::balance<FakeMoney>(@0x234) == 85, 1);
        assert!(coin::balance<FakeMoney>(@0x345) == 80, 2);
        assert!(coin::balance<FakeMoney>(@0x456) == 102, 3);
        assert!(object::is_owner(obj, @0x345), 4);

        timestamp::update_global_time_for_test(6000_000 + 86400_000_000 + 86400_000_000);
        bids::withdraw_from_expired<FakeMoney>(bidder_1);
        assert!(coin::balance<FakeMoney>(@0x234) == 100, 5);

        components_common::destroy_for_test(ret);
    }
}