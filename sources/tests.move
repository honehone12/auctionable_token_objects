#[test_only]
module token_objects_marketplace::tests {
    use std::signer;
    use std::option;
    use std::string::utf8;
    use aptos_framework::timestamp;
    use aptos_framework::object::{Self, Object};
    use token_objects::collection;
    use token_objects::token;
    use token_objects::royalty;
    use token_objects_marketplace::tradings;

    struct FreePizzaPass has key {}

    fun setup_test(framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
    }

    fun create_test_object(creator: &signer): Object<FreePizzaPass> {
        _ = collection::create_untracked_collection(
            creator,
            utf8(b"collection description"),
            collection::create_mutability_config(false, false),
            utf8(b"collection"),
            option::none(),
            utf8(b"collection uri"),
        );
        let cctor = token::create_token(
            creator,
            utf8(b"collection"),
            utf8(b"description"),
            token::create_mutability_config(false, false, false),
            utf8(b"name"),
            option::some(royalty::create(10, 100, signer::address_of(creator))),
            utf8(b"uri")
        );
        move_to(&object::generate_signer(&cctor), FreePizzaPass{});
        tradings::init_with_constructor_ref<FreePizzaPass>(
            &cctor, 
            utf8(b"collection"), utf8(b"name")
        );
        object::object_from_constructor_ref<FreePizzaPass>(&cctor)
    }

    #[test(creator = @0x123, framework = @0x1)]
    fun test_happy_path(creator: &signer, framework: &signer) {
        setup_test(framework);
        let obj = create_test_object(creator);
        tradings::start_auction(
            creator,
            obj, 
            utf8(b"collection"), utf8(b"name"),
            false,
            10,
            1
        );
    }
}